@echo off

REM Tell the user that we are compiling the mod

echo Compiling source code for LagCompensation

REM Run UCC.exe from inside LagCompensation\System, so that the
REM compiler uses the mod's initialisation files and settings
REM and stores the compiled output in the LagCompensation\System
REM directory.
REM
REM Packages rebuilt from modified retail code (SwatEquipment and the
REM packages that depend on it) are automatically conformed to the
REM originals in ..\SystemConform, so they keep the retail GUID and
REM unmodified clients can still join the server.

cd .\System\

if exist LagCompensation.u del LagCompensation.u

..\..\Content\System\UCC.exe make -nobind

REM Tell the user that the compiler has exited, and wait for a keypress

echo Finished compiling LagCompensation
PAUSE
