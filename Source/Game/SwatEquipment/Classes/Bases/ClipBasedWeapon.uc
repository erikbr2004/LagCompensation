class ClipBasedWeapon extends Engine.FiredWeapon;

simulated function EquippedHook()
{
    Super.EquippedHook();

    Ammo.UpdateHUD(); 
}

//simulated function UnEquippedHook();  //TMC do we want to blank the HUD's ammo count?

//lag compensation: on a server running a LagCompensationHook, shots from
//  remote players are resolved against the positions they saw on screen
simulated function BallisticFire(vector StartTrace, vector EndTrace)
{
    if (!class'LagCompensationHook'.static.HandleBallisticFire(self, StartTrace, EndTrace))
        Super.BallisticFire(StartTrace, EndTrace);
}
