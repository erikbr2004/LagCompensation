///////////////////////////////////////////////////////////////////////////////
//
// Server side hook that lets a lag compensation implementation resolve
// ballistic shots fired by remote players.
//
// ClipBasedWeapon and RoundBasedWeapon route BallisticFire() through
// HandleBallisticFire(). When no hook actor exists (clients, standalone games,
// servers without the mod) the stock BallisticFire() runs unchanged.
//
// This class only declares the interface; the implementation lives in a
// separate, server-only package and is spawned through ServerActors.
//

class LagCompensationHook extends Engine.Info
    abstract;

// Override in a subclass. Return true when the shot was fully resolved,
// false to let the weapon run the stock BallisticFire().
function bool CompensateBallisticFire(FiredWeapon Weapon, vector StartTrace, vector EndTrace)
{
    return false;
}

static function bool HandleBallisticFire(FiredWeapon Weapon, vector StartTrace, vector EndTrace)
{
    local LagCompensationHook Hook;

    if (Weapon == None
        || Weapon.Level.NetMode == NM_Client
        || Weapon.Level.NetMode == NM_Standalone)
        return false;

    foreach Weapon.DynamicActors(class'LagCompensationHook', Hook)
        return Hook.CompensateBallisticFire(Weapon, StartTrace, EndTrace);

    return false;
}

defaultproperties
{
    RemoteRole=ROLE_None
}
