///////////////////////////////////////////////////////////////////////////////
//
// LagCompensation - server only lag compensation for SWAT 4 multiplayer.
//
// Spawned on the server through [Engine.GameEngine] ServerActors and never
// replicated, so clients do not need this package.
//
// How it works:
//  * Every SampleInterval seconds the position of every tracked pawn is stored
//    in a ring buffer (about 64 samples per pawn).
//  * When a remote player fires, the weapon asks this hook to resolve the shot
//    (see SwatEquipment.LagCompensationHook). The shot is evaluated at the
//    moment the shooter saw it: now - (round trip time + one server frame).
//  * Targets are never moved. For every target that changed position since
//    then, the bullet ray is shifted by that displacement and traced against
//    the target's current body, which is equivalent to tracing the original
//    ray against the target's past position. The world is still traced with
//    the original ray, so walls keep blocking and penetration still works.
//  * All hits are sorted by distance along the original ray and handed to the
//    stock FiredWeapon.HandleBallisticImpact(), so damage, armor, penetration
//    and effects behave exactly like the unmodified game.
//
// Limitations: only the position is rewound, not the animation pose (crouch,
// lean) nor the body rotation.
//

// Configuration lives in the server's main ini (Swat4DedicatedServer.ini or
// Swat4.ini), section [LagCompensation.LagCompensationManager]. Those files are
// excluded from SWAT's config MD5 check; any other new .ini file would make
// unmodified clients fail to connect ("unexpected number of configuration
// files").
class LagCompensationManager extends SwatEquipment.LagCompensationHook
    config;

const kHistorySize = 64;
const kMinOffset   = 1.0;   // displacements smaller than this are ignored (unreal units)

struct PawnHistory
{
    var Pawn   Target;
    var float  SampleTime[64];
    var vector SampleLocation[64];
    var int    Newest;          // index of the newest sample
    var int    Count;           // number of valid samples
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
    var float           Distance;   // along the original ray
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
var config bool  bLogShots;              // log every compensated shot (for tuning)

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

///////////////////////////////////////////////////////////////////////////////

event PostBeginPlay()
{
    Super.PostBeginPlay();

    log("LagCompensation: enabled="$bEnabled$" MaxRewindTime="$MaxRewindTime
        $" PingScale="$PingScale$" ExtraRewindTime="$ExtraRewindTime
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
    Histories[i].Newest = Next;
    Histories[i].Count = Min(Histories[i].Count + 1, kHistorySize);
}

// Interpolated position of history entry i at game time T.
private function bool GetPastLocation(int i, float T, out vector PastLocation)
{
    local int Newer, Older, Step;
    local float Alpha;

    if (Histories[i].Count == 0)
        return false;

    Newer = Histories[i].Newest;
    if (T >= Histories[i].SampleTime[Newer])
    {
        PastLocation = Histories[i].Target.Location;
        return true;
    }

    for (Step = 1; Step < Histories[i].Count; ++Step)
    {
        Older = (Newer - 1 + kHistorySize) % kHistorySize;

        if (Histories[i].SampleTime[Older] <= T)
        {
            Alpha = (T - Histories[i].SampleTime[Older])
                  / FMax(Histories[i].SampleTime[Newer] - Histories[i].SampleTime[Older], 0.0001);
            PastLocation = Histories[i].SampleLocation[Older]
                         + (Histories[i].SampleLocation[Newer] - Histories[i].SampleLocation[Older]) * Alpha;
            return true;
        }

        Newer = Older;
    }

    // Older than the whole history: use the oldest sample.
    PastLocation = Histories[i].SampleLocation[Newer];
    return true;
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
    local vector PastLocation, Offset, Direction;
    local array<Pawn> Targets;
    local array<vector> Offsets;
    local array<BallisticHit> Hits;
    local BallisticHit Hit;
    local Actor Victim;
    local int i, t;

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

    // Targets that were somewhere else on the shooter's screen.
    for (i = 0; i < Histories.Length; ++i)
    {
        Target = Histories[i].Target;
        if (Target == None || Target == Shooter || Target.bDeleteMe
            || !Target.bCollideActors || Target.IsDead())
            continue;

        if (!GetPastLocation(i, ShotTime, PastLocation))
            continue;

        Offset = Target.Location - PastLocation;
        if (VSize(Offset) < kMinOffset)
            continue;

        Targets[Targets.Length] = Target;
        Offsets[Offsets.Length] = Offset;
    }

    if (Targets.Length == 0)
        return false;   // nobody moved: the stock code gives the same result

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
        if (IndexOfPawn(Targets, Victim) >= 0)
            continue;

        Hit.Victim = Victim;
        Hit.Distance = VSize(Hit.HitLocation - StartTrace);
        AddHit(Hits, Hit);
    }

    // 2. Each compensated pawn, hit by the ray shifted by its displacement.
    for (t = 0; t < Targets.Length; ++t)
    {
        foreach Weapon.TraceActors(
            class'Actor', Victim,
            Hit.HitLocation, Hit.HitNormal, Hit.HitMaterial,
            EndTrace + Offsets[t], StartTrace + Offsets[t],
            /*optional extent*/,
            true,
            Hit.HitRegion,
            true,
            true,
            Hit.ExitLocation, Hit.ExitNormal, Hit.ExitMaterial)
        {
            if (Victim != Targets[t])
                continue;

            Hit.Victim = Victim;
            Hit.Distance = VSize(Hit.HitLocation - Offsets[t] - StartTrace);
            AddHit(Hits, Hit);

            if (bLogShots)
                log("LagCompensation: "$Shooter.GetHumanReadableName()$" hit "$Victim.GetHumanReadableName()
                    $" rewound "$int(RewindTime * 1000)$"ms ("$int(VSize(Offsets[t]))$"uu)");
            break;
        }
    }

    // 3. Resolve the impacts in order, exactly like FiredWeapon.BallisticFire().
    Momentum = Weapon.MuzzleVelocity * Weapon.Ammo.Mass;
    Direction = Normal(EndTrace - StartTrace);

    for (i = 0; i < Hits.Length; ++i)
    {
        if (!Weapon.HandleBallisticImpact(
                Hits[i].Victim,
                Hits[i].HitLocation,
                Hits[i].HitNormal,
                Direction,
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

private function int IndexOfPawn(array<Pawn> List, Actor A)
{
    local int i;

    for (i = 0; i < List.Length; ++i)
    {
        if (List[i] == A)
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
    bLogShots=false
}
