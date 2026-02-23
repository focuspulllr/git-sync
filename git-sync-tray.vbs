Set WshShell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
ps1Path = scriptDir & "\git-sync-tray.ps1"
WshShell.Run "powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1Path & """", 0, False
