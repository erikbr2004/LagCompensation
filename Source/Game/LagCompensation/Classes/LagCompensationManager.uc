///////////////////////////////////////////////////////////////////////////////
//
// LagCompensation - server only lag compensation for SWAT 4 multiplayer.
//
// Spawned on the server through [Engine.GameEngine] ServerActors and never
// replicated, so clients do not need this package.
//
// How it works:
//  * Every SampleInterval seconds the position, body yaw and crouch/lean state
//    of every tracked pawn are stored in a ring buffer (64 samples per pawn).
//  * When a remote player fires, the weapon asks this hook to resolve the shot
//    (see SwatEquipment.LagCompensationHook). The shot is evaluated at the
//    moment the shooter saw it: now - (round trip time + one server frame).
//  * Targets are never moved. For every target that moved or turned since
//    then, the bullet ray is carried by the same rigid transform (translation
//    and yaw rotation around the pawn) from the target's past frame into its
//    current frame, and traced against the target's current body. That is
//    equivalent to tracing the original ray against the target's past
//    position and orientation. The world is still traced with the original
//    ray, so walls keep blocking and penetration still works.
//  * All hits are sorted by distance along the original ray and handed to the
//    stock FiredWeapon.HandleBallisticImpact(), so damage, armor, penetration
//    and effects behave exactly like the unmodified game.
//
// Limitations: the animation pose (crouch, lean, upper body aim) is not
// rewound. It is recorded, and impacts on targets whose crouch/lean state
// changed within the rewind window are counted and logged (bLogShots), to
// measure how often that matters.
//

// Configuration lives in the server's main ini (Swat4DedicatedServer.ini or
// Swat4.ini), section [LagCompensation.LagCompensationManager]. Those files are
// excluded from SWAT's config MD5 check; any other new .ini file would make
// unmodified clients fail to connect ("unexpected number of configuration
// files").
class LagCompensationManager extends SwatEquipment.LagCompensationHook
    config;

const kVersion       = "1.0.2";
const kHistorySize   = 64;
const kMinOffset     = 1.0;     // displacements smaller than this are ignored (unreal units)
const kMinYawDelta   = 182;     // turns smaller than this are ignored (182 = 1 degree)

// Pose bits stored in PawnHistory.SamplePose.
const kPoseCrouched  = 1;
const kPoseLeanLeft  = 2;
const kPoseLeanRight = 4;

struct PawnHistory
{
    var Pawn   Target;
    var float  SampleTime[64];
    var vector SampleLocation[64];
    var int    SampleYaw[64];       // body yaw, 0..65535
    var byte   SamplePose[64];      // kPose* bits
    var int    Newest;              // index of the newest sample
    var int    Count;               // number of valid samples
};

// A target that is compensated for the current shot.
struct RewoundTarget
{
    var Pawn    Target;
    var vector  PastLocation;
    var rotator PastRotation;       // yaw only
    var vector  CurrentLocation;
    var rotator CurrentRotation;    // yaw only
    var int     YawDelta;           // current - past, -32768..32767
    var byte    PastPose;
    var byte    CurrentPose;
    var bool    bPoseChanged;       // crouch/lean changed between the shot time and now
};

struct BallisticHit
{
    var Actor           Victim;
    var vector          HitLocation;
    var vector          HitNormal;
    var Material        HitMaterial;
    var ESkeletalRegion HitRegion;
    var vector          ExitLocation;
    var vector          ExitNormal;
    var Material        ExitMaterial;
    var vector          Direction;      // bullet direction in the frame of the hit
    var float           Distance;       // along the original ray
    var int             RewoundIndex;   // index into the shot's RewoundTarget list, -1 if none
};

// Server configuration ([LagCompensation.LagCompensationManager] in the main ini).
var config bool  bEnabled;
var config float MaxRewindTime;          // seconds; upper bound for any rewind
var config float PingScale;              // fraction of the round trip time to rewind
var config float ExtraRewindTime;        // seconds added to every rewind
var config bool  bAddServerFrameTime;    // add the average server frame time to the rewind
var config bool  bUseServerMeasuredPing; // prefer the server's own ping measurement
var config float SampleInterval;         // seconds between position samples
var config float TeleportDistance;       // a jump larger than this resets a pawn's history
var config bool  bCompensateAI;          // also compensate AI pawns (COOP)
var config bool  bCompensateRotation;    // also rewind the target's body yaw
var config bool  bLogShots;              // log compensated impacts (for tuning)
var config bool  bLogPoseChangesOnly;    // with bLogShots, only log impacts whose target changed pose

struct PingInfo
{
    var PlayerController Controller;
    var float            RoundTrip;    // real seconds
    var float            NextUpdate;   // game time
};

var private array<PawnHistory> Histories;
var private array<PingInfo> PingCache;
var private float LastSampleTime;
var private float AverageFrameTime;

// Statistics for the current map (the manager is spawned again on every map).
var private int CompensatedImpacts;      // impacts on compensated targets
var private int PoseChangedImpacts;      // ... whose crouch/lean changed within the rewind window

///////////////////////////////////////////////////////////////////////////////

event PostBeginPlay()
{
    Super.PostBeginPlay();

    log("LagCompensation "$kVersion$": enabled="$bEnabled$" rotation="$bCompensateRotation
        $" MaxRewindTime="$MaxRewindTime$" PingScale="$PingScale$" ExtraRewindTime="$ExtraRewindTime
        $" history="$(kHistorySize * SampleInterval)$"s");
}

event Tick(float DeltaTime)
{
    local Pawn P;

    if (!bEnabled)
        return;

    AverageFrameTime = AverageFrameTime * 0.9 + DeltaTime * 0.1;

    if (Level.TimeSeconds - LastSampleTime < SampleInterval)
        return;
    LastSampleTime = Level.TimeSeconds;

    PruneHistories();

    foreach DynamicActors(class'Pawn', P)
    {
        if (ShouldTrack(P))
            RecordSample(P);
    }
}

///////////////////////////////////////////////////////////////////////////////
// History

private function bool ShouldTrack(Pawn P)
{
    if (P == None || P.bDeleteMe || !P.bCollideActors || P.IsDead())
        return false;

    return P.IsA('NetPlayer') || bCompensateAI;
}

private function PruneHistories()
{
    local int i;

    for (i = Histories.Length - 1; i >= 0; --i)
    {
        if (Histories[i].Target == None || Histories[i].Target.bDeleteMe)
            Histories.Remove(i, 1);
    }

    for (i = PingCache.Length - 1; i >= 0; --i)
    {
        if (PingCache[i].Controller == None || PingCache[i].Controller.bDeleteMe)
            PingCache.Remove(i, 1);
    }
}

private function int FindHistory(Pawn P)
{
    local int i;

    for (i = 0; i < Histories.Length; ++i)
    {
        if (Histories[i].Target == P)
            return i;
    }

    return -1;
}

private function RecordSample(Pawn P)
{
    local int i, Next;

    i = FindHistory(P);
    if (i < 0)
    {
        i = Histories.Length;
        Histories.Length = i + 1;
        Histories[i].Target = P;
        Histories[i].Newest = 0;
        Histories[i].Count = 0;
    }

    // Respawns and teleports must not be interpolated across.
    if (Histories[i].Count > 0
        && VSize(P.Location - Histories[i].SampleLocation[Histories[i].Newest]) > TeleportDistance)
        Histories[i].Count = 0;

    Next = (Histories[i].Newest + 1) % kHistorySize;
    Histories[i].SampleTime[Next] = Level.TimeSeconds;
    Histories[i].SampleLocation[Next] = P.Location;
    Histories[i].SampleYaw[Next] = P.Rotation.Yaw & 65535;
    Histories[i].SamplePose[Next] = GetPose(P);
    Histories[i].Newest = Next;
    Histories[i].Count = Min(Histories[i].Count + 1, kHistorySize);
}

// State of history entry i at game time T: position (interpolated), body yaw
// (interpolated along the shortest arc) and crouch/lean pose (the last one
// recorded at or before T). PoseChanged is 1 when any sample between T and now
// has a different pose than the target has now (a byte, because UnrealScript
// does not allow bool out parameters).
private function bool GetPastState(int i, float T, out vector PastLocation, out int PastYaw,
                                   out byte PastPose, out byte PoseChanged)
{
    local int Newer, Older, Step;
    local float Alpha;
    local byte CurrentPose;
    local Pawn Target;

    Target = Histories[i].Target;
    CurrentPose = GetPose(Target);
    PoseChanged = 0;

    if (Histories[i].Count == 0)
        return false;

    Newer = Histories[i].Newest;
    if (T >= Histories[i].SampleTime[Newer])
    {
        PastLocation = Target.Location;
        PastYaw = Target.Rotation.Yaw & 65535;
        PastPose = CurrentPose;
        return true;
    }

    if (Histories[i].SamplePose[Newer] != CurrentPose)
        PoseChanged = 1;

    for (Step = 1; Step < Histories[i].Count; ++Step)
    {
        Older = (Newer - 1 + kHistorySize) % kHistorySize;

        if (Histories[i].SamplePose[Older] != CurrentPose)
            PoseChanged = 1;

        if (Histories[i].SampleTime[Older] <= T)
        {
            Alpha = (T - Histories[i].SampleTime[Older])
                  / FMax(Histories[i].SampleTime[Newer] - Histories[i].SampleTime[Older], 0.0001);
            PastLocation = Histories[i].SampleLocation[Older]
                         + (Histories[i].SampleLocation[Newer] - Histories[i].SampleLocation[Older]) * Alpha;
            PastYaw = Histories[i].SampleYaw[Older]
                    + int(float(NormalizeYawDelta(Histories[i].SampleYaw[Newer] - Histories[i].SampleYaw[Older])) * Alpha);
            PastPose = Histories[i].SamplePose[Older];
            return true;
        }

        Newer = Older;
    }

    // Older than the whole history: use the oldest sample.
    PastLocation = Histories[i].SampleLocation[Newer];
    PastYaw = Histories[i].SampleYaw[Newer];
    PastPose = Histories[i].SamplePose[Newer];
    return true;
}

private function byte GetPose(Pawn P)
{
    local byte Pose;

    if (P.bIsCrouched)
        Pose = kPoseCrouched;

    if (P.LeanState == kLeanStateLeft)
        Pose += kPoseLeanLeft;
    else if (P.LeanState == kLeanStateRight)
        Pose += kPoseLeanRight;

    return Pose;
}

private function string PoseToString(byte Pose)
{
    local string S;

    if ((Pose & kPoseCrouched) != 0)
        S = "crouched";
    else
        S = "standing";

    if ((Pose & kPoseLeanLeft) != 0)
        S = S$"+lean left";
    else if ((Pose & kPoseLeanRight) != 0)
        S = S$"+lean right";

    return S;
}

// Wraps a yaw difference to -32768..32767 (the shortest way around).
private function int NormalizeYawDelta(int Delta)
{
    Delta = Delta & 65535;
    if (Delta > 32767)
        Delta -= 65536;

    return Delta;
}

private function rotator YawRotator(int Yaw)
{
    local rotator R;

    R.Yaw = Yaw;
    return R;
}

// Carries a world point from the target's past frame into its current frame:
// the same rigid transform the target's body went through since the shot time.
private function vector PastToCurrent(vector Point, RewoundTarget R)
{
    if (!bCompensateRotation)
        return Point + (R.CurrentLocation - R.PastLocation);

    return R.CurrentLocation + (((Point - R.PastLocation) << R.PastRotation) >> R.CurrentRotation);
}

///////////////////////////////////////////////////////////////////////////////
// Latency

// Round trip time in real seconds, refreshed at most once per second.
private function float GetRoundTripTime(PlayerController PC)
{
    local int i, PingMs;

    for (i = 0; i < PingCache.Length; ++i)
    {
        if (PingCache[i].Controller == PC)
            break;
    }

    if (i == PingCache.Length)
    {
        PingCache.Length = i + 1;
        PingCache[i].Controller = PC;
        PingCache[i].NextUpdate = 0;
    }

    if (Level.TimeSeconds >= PingCache[i].NextUpdate)
    {
        if (bUseServerMeasuredPing)
            PingMs = int(PC.ConsoleCommand("GETPING"));

        if (PingMs <= 0 && PC.PlayerReplicationInfo != None)
            PingMs = PC.PlayerReplicationInfo.Ping;

        PingCache[i].RoundTrip = FMax(PingMs, 0) / 1000.0;
        PingCache[i].NextUpdate = Level.TimeSeconds + 1.0;
    }

    return PingCache[i].RoundTrip;
}

// How far back in game time the shooter's view is.
private function float GetRewindTime(PlayerController PC)
{
    local float Rewind;

    Rewind = (GetRoundTripTime(PC) * PingScale + ExtraRewindTime) * Level.TimeDilation;

    if (bAddServerFrameTime)
        Rewind += AverageFrameTime;

    return FClamp(Rewind, 0.0, MaxRewindTime * Level.TimeDilation);
}

///////////////////////////////////////////////////////////////////////////////
// Shot resolution

function bool CompensateBallisticFire(FiredWeapon Weapon, vector StartTrace, vector EndTrace)
{
    local Pawn Shooter, Target;
    local PlayerController PC;
    local float RewindTime, ShotTime, Momentum;
    local RewoundTarget R;
    local array<RewoundTarget> Rewound;
    local array<BallisticHit> Hits;
    local BallisticHit Hit;
    local Actor Victim;
    local vector RayStart, RayEnd;
    local int PastYaw, i, t;
    local byte PoseChanged;

    if (!bEnabled || Weapon == None || Weapon.Ammo == None)
        return false;

    Shooter = Pawn(Weapon.Owner);
    if (Shooter == None)
        return false;

    // Only remote human players have latency to compensate.
    PC = PlayerController(Shooter.Controller);
    if (PC == None || PC == Level.GetLocalPlayerController())
        return false;

    RewindTime = GetRewindTime(PC);
    if (RewindTime <= 0)
        return false;
    ShotTime = Level.TimeSeconds - RewindTime;

    // Targets that were somewhere else, faced another way or had another pose
    // on the shooter's screen.
    for (i = 0; i < Histories.Length; ++i)
    {
        Target = Histories[i].Target;
        if (Target == None || Target == Shooter || Target.bDeleteMe
            || !Target.bCollideActors || Target.IsDead())
            continue;

        if (!GetPastState(i, ShotTime, R.PastLocation, PastYaw, R.PastPose, PoseChanged))
            continue;

        R.Target = Target;
        R.CurrentLocation = Target.Location;
        R.PastRotation = YawRotator(PastYaw);
        R.CurrentRotation = YawRotator(Target.Rotation.Yaw & 65535);
        R.YawDelta = NormalizeYawDelta(R.CurrentRotation.Yaw - PastYaw);
        R.CurrentPose = GetPose(Target);
        R.bPoseChanged = (PoseChanged != 0);

        if (VSize(R.CurrentLocation - R.PastLocation) < kMinOffset
            && (!bCompensateRotation || Abs(R.YawDelta) < kMinYawDelta)
            && !R.bPoseChanged)
            continue;

        Rewound[Rewound.Length] = R;
    }

    if (Rewound.Length == 0)
        return false;   // nobody moved, turned or changed pose: the stock code gives the same result

    // 1. The original ray, minus the compensated pawns (they were not there).
    foreach Weapon.TraceActors(
        class'Actor', Victim,
        Hit.HitLocation, Hit.HitNormal, Hit.HitMaterial,
        EndTrace, StartTrace,
        /*optional extent*/,
        true,   //bSkeletalBoxTest
        Hit.HitRegion,
        true,   //bGetMaterial
        true,   //bFindExitLocation
        Hit.ExitLocation, Hit.ExitNormal, Hit.ExitMaterial)
    {
        if (IndexOfRewound(Rewound, Victim) >= 0)
            continue;

        Hit.Victim = Victim;
        Hit.Direction = Normal(Hit.HitLocation - StartTrace);
        Hit.Distance = VSize(Hit.HitLocation - StartTrace);
        Hit.RewoundIndex = -1;
        AddHit(Hits, Hit);
    }

    // 2. Each compensated pawn, hit by the ray carried into its current frame.
    for (t = 0; t < Rewound.Length; ++t)
    {
        RayStart = PastToCurrent(StartTrace, Rewound[t]);
        RayEnd = PastToCurrent(EndTrace, Rewound[t]);

        foreach Weapon.TraceActors(
            class'Actor', Victim,
            Hit.HitLocation, Hit.HitNormal, Hit.HitMaterial,
            RayEnd, RayStart,
            /*optional extent*/,
            true,
            Hit.HitRegion,
            true,
            true,
            Hit.ExitLocation, Hit.ExitNormal, Hit.ExitMaterial)
        {
            if (Victim != Rewound[t].Target)
                continue;

            Hit.Victim = Victim;
            Hit.Direction = Normal(Hit.HitLocation - RayStart);
            // The transform is rigid, so this is also the distance along the original ray.
            Hit.Distance = VSize(Hit.HitLocation - RayStart);
            Hit.RewoundIndex = t;
            AddHit(Hits, Hit);
            break;
        }
    }

    // 3. Resolve the impacts in order, exactly like FiredWeapon.BallisticFire().
    Momentum = Weapon.MuzzleVelocity * Weapon.Ammo.Mass;

    for (i = 0; i < Hits.Length; ++i)
    {
        if (Hits[i].RewoundIndex >= 0)
            NoteCompensatedImpact(Shooter, Rewound[Hits[i].RewoundIndex], RewindTime);

        if (!Weapon.HandleBallisticImpact(
                Hits[i].Victim,
                Hits[i].HitLocation,
                Hits[i].HitNormal,
                Hits[i].Direction,
                Hits[i].HitMaterial,
                Hits[i].HitRegion,
                Momentum,
                Hits[i].ExitLocation,
                Hits[i].ExitNormal,
                Hits[i].ExitMaterial))
            break;
    }

    return true;
}

// Called when a bullet actually reaches a compensated target (after walls and
// anything else in front of it have been resolved).
private function NoteCompensatedImpact(Pawn Shooter, RewoundTarget R, float RewindTime)
{
    local string Kind;

    ++CompensatedImpacts;
    if (R.bPoseChanged)
        ++PoseChangedImpacts;

    if (!bLogShots)
        return;

    if (R.bPoseChanged || !bLogPoseChangesOnly)
    {
        if (R.bPoseChanged)
            Kind = "POSE CHANGED";
        else
            Kind = "hit";

        log("LagCompensation: "$Kind$" "$Shooter.GetHumanReadableName()$" -> "$R.Target.GetHumanReadableName()
            $" rewound "$int(RewindTime * 1000)$"ms, moved "$int(VSize(R.CurrentLocation - R.PastLocation))
            $"uu, turned "$int(Abs(R.YawDelta) * 360.0 / 65536.0)$"deg, pose "$PoseToString(R.PastPose)
            $" -> "$PoseToString(R.CurrentPose)$" [pose changed "$PoseChangedImpacts$"/"$CompensatedImpacts$"]");
    }

    if (CompensatedImpacts % 100 == 0)
        log("LagCompensation: summary - "$CompensatedImpacts$" compensated impacts on this map, "
            $PoseChangedImpacts$" on targets whose crouch/lean changed within the rewind window ("
            $(float(PoseChangedImpacts) * 100.0 / float(CompensatedImpacts))$"%)");
}

private function int IndexOfRewound(array<RewoundTarget> List, Actor A)
{
    local int i;

    for (i = 0; i < List.Length; ++i)
    {
        if (List[i].Target == A)
            return i;
    }

    return -1;
}

// Inserts keeping the list sorted by Distance.
private function AddHit(out array<BallisticHit> Hits, BallisticHit NewHit)
{
    local int i;

    i = Hits.Length;
    while (i > 0 && Hits[i - 1].Distance > NewHit.Distance)
        --i;

    Hits.Insert(i, 1);
    Hits[i] = NewHit;
}

///////////////////////////////////////////////////////////////////////////////

defaultproperties
{
    bEnabled=true
    MaxRewindTime=0.5
    PingScale=1.0
    ExtraRewindTime=0.0
    bAddServerFrameTime=true
    bUseServerMeasuredPing=true
    SampleInterval=0.01
    TeleportDistance=512
    bCompensateAI=true
    bCompensateRotation=true
    bLogShots=false
    bLogPoseChangesOnly=false
}
