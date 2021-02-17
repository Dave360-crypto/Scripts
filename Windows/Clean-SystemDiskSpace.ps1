#requires -Version 2
#Designed to work with PowerShell 2-5 to support Windows 7 - Windows 10 native PowerShell

#Set-StrictMode -Version Latest #i.e. Option Explicit (all variables must be declared)
################################################################################
#.SYNOPSIS
#	Clean-SystemDiskSpace.ps1
#	Remove known temp and unwanted files
#.DESCRIPTION
#   Old installs of Windows 7 may need http://support.microsoft.com/kb/2852386
#.PARAMETER MinimumFreeMB
#   Specifies the amount of free disk space the system drive (C:\) must have before ceasing to cleanup
#   If not specified, 25 GB / 25600 MB will be used to support Windows 10 upgrades
#   If 0 is specified, then all routines will run regardless of the amount of free disk space
#.PARAMETER FileAgeInDays
#.PARAMETER ProfileAgeInDays
#.OUTPUTS
#   Exits with 0 if the specified free space has been achieved
#   Exits with 112 / 0x00000070 / ERROR_DISK_FULL / There is not enough space on the disk.  This is a ConfigMgr FailRetry error number
#   Exits with appropriate code if a fatal error occurs
#.EXAMPLE
#	Clean-SystemDiskSpace.ps1
#.EXAMPLE
#   PowerShell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File Clean-SystemDiskSpace.ps1 -MinimumFreeMB 25600
#.LINK
#   This script is maintained at https://github.com/ChadSimmons/Scripts
#.NOTES
#   Additional information about the function or script.
#   ========== Keywords ==========
#   Keywords: Free Disk Space Cleanup
#   ========== Change Log History ==========
#   - 2021/02/17 by Chad.Simmons@CatapultSystems.com - major rewrite
#   - 2017/06/09 by Chad.Simmons@CatapultSystems.com - Created
#   - 2017/06/09 by Chad@ChadsTech.net - Created
#   === To Do / Proposed Changes ===
#	#ENHANCEMENT: Add ShouldProcess / WhatIf support
#	#ENHANCEMENT: Log space savings summary (and per clean up group?) (file/folder count, MB)
#	       from http://powershell.com/cs/blogs/tips/archive/2016/05/31/cleaning-week-deleting-log-file-backups.aspx
#          and  http://powershell.com/cs/blogs/tips/archive/2016/05/30/cleaning-week-finding-fat-log-file-backups.aspx
#	#ENHANCEMENT: Log action transactions in CSV
#	#See additional TODO tags in the script body
#   ========== Additional References and Reading ==========
#	- Microsoft CleanMgr https://docs.microsoft.com/en-us/windows-server/administration/windows-commands/cleanmgr
#   - https://gregramsey.net/2014/05/14/automating-the-disk-cleanup-utility/
#   - https://gallery.technet.microsoft.com/scriptcenter/How-to-Delete-the-912d772b#content
#   - https://www.autoitscript.com/forum/topic/78893-automate-disk-cleanup-cleanmgrexe/
#   - https://msdn.microsoft.com/en-us/library/windows/desktop/bb776782%28v=vs.85%29.aspx
#   - https://social.technet.microsoft.com/Forums/systemcenter/en-US/c4fa8bbe-8aeb-4fc6-a5c6-b57c2680ac8a/vbscript-cleanmgr-for-all-users?forum=w7itprogeneral
#   - https://serverfault.com/questions/545579/properly-remove-windows-old-on-hyper-v-server-2012-r2
#	- https://garytown.com/clean-up-storage-pre-upgrade
#   - https://www.jaapbrasser.com/diskcleanup-remove-previous-windows-versions-powershell-module/

#	- http://powershell.com/cs/blogs/tips/archive/2016/05/27/cleaning-week-deleting-temp-files.aspx
#   - http://powershell.com/cs/blogs/tips/archive/2016/05/26/cleaning-week-find-data-garbage.aspx
#   - https://deployhappiness.com/automatic-disk-cleanup-with-group-policy-and-sccm
#   - http://tdemeul.bunnybesties.org/2018/05/sccm-clear-ccmcache-remotely.html

################################################################################


#region    ######################### Parameters and variable initialization ####
[CmdletBinding()] #(SupportsShouldProcess=$false, ConfirmImpact="Low")
Param (
    [Parameter()][int32]$MinimumFreeMB = 25600, #25GB is generally needed to upgrade Windows 10
    [Parameter()][int16]$FileAgeInDays = 8, #age (creation date) of files to delete
    [Parameter()][int16]$ProfileAgeInDays = 90, #age of user profiles to delete
	[Parameter()]$LogFile #The default is determined automatically if not specified
)
#endregion ######################### Parameters and variable initialization ####

#region    ######################### Functions #################################
################################################################################
################################################################################
Function Get-CurrentLineNumber {
	If ($psISE) { $script:CurrentLine = $psISE.CurrentFile.Editor.CaretLine }
	Else { $script:CurrentLine = $MyInvocation.ScriptLineNumber }
	return $script:CurrentLine
}
Function Get-CurrentFunctionName {
	return (Get-Variable MyInvocation -Scope 1).Value.MyCommand.Name
}
Function Get-ScriptInfo ([string]$ScriptFile = $ScriptFullPath) {
	#.Synopsis
	#   Get the name and path of the script file
	#.Description
	#   Sets global variables for ScriptStartTime, ScriptNameAndPath, ScriptPath, ScriptName, ScriptBaseName, and ScriptLog
	#   This function works inline or in a dot-sourced script
	#   See snippet Get-ScriptInfo.ps1 for excruciating details and alternatives
	Write-Verbose -Message "Start Function: $(Get-CurrentFunctionName) -FullPath [$ScriptFile]"
	If (Test-Path -LiteralPath variable:script:ScriptInfo) {
		Write-Verbose 'ScriptInfo already set.  Resetting Times'
		$ScriptInfo.StartTime = $(Get-Date)
		$ScriptInfo.EndTime = $null
	} ElseIf ($ScriptInfo -is [object]) {
		Write-Verbose 'ScriptInfo already set.  Resetting Times'
		$ScriptInfo.StartTime = $(Get-Date)
		$ScriptInfo.EndTime = $null
	} Else {
		$script:ScriptInfo = New-Object -TypeName PSObject
		Add-Member -InputObject $script:ScriptInfo -MemberType NoteProperty -Name 'StartTime' -Value $(Get-Date) #-Description 'The date and time the script started'
		Add-Member -InputObject $script:ScriptInfo -MemberType NoteProperty -Name 'EndTime' -Value $Null #-Description 'The date and time the script completed'

		If ([string]::IsNullorEmpty($ScriptFile) -or (-not(Test-Path -Path $ScriptFile))) {
			#The ScriptNameAndPath was not passed, thus detect it
			If ($psISE) {
				Add-Member -InputObject $script:ScriptInfo -MemberType NoteProperty -Name 'FullPath' -Value $psISE.CurrentFile.FullPath #-Description 'The full path/folder/directory, name, and extension script file'
				Write-Verbose "Invoked ScriptPath from dot-sourced Script Function: $($ScriptInfo.FullPath)"
			} ElseIf ($((Get-Variable MyInvocation -Scope 1).Value.InvocationName) -eq '.') {
				#this script has been dot-sourced... https://stackoverflow.com/questions/4875912/determine-if-powershell-script-has-been-dot-sourced
				Add-Member -InputObject $script:ScriptInfo -MemberType NoteProperty -Name 'FullPath' -Value (Get-Variable MyInvocation -Scope 1).Value.ScriptName #-Description 'The full path/folder/directory, name, and extension script file'
				Write-Verbose "Invoked ScriptPath from dot-sourced Script Function: $($ScriptInfo.FullPath)"
			} Else {
				Add-Member -InputObject $script:ScriptInfo -MemberType NoteProperty -Name 'FullPath' -Value $script:MyInvocation.MyCommand.Path #-Description 'The full path/folder/directory, name, and extension script file'
				Write-Verbose "Invoked ScriptPath from Invoked Script Function: $($ScriptInfo.FullPath)"
			}
		} else {
			Add-Member -InputObject $script:ScriptInfo -MemberType NoteProperty -Name 'FullPath' -Value $ScriptFile #-Description 'The full path/folder/directory, name, and extension script file'
		}
		#Get Timezone if not already defined #from Utility.ps1 by Duane.Gardiner@1e.com version 2.0 modified  2014/04/02
		[string]$local:TimezoneBias = [System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalMinutes
		If ( $local:TimezoneBias -match "^-" ) {
			$local:TimezoneBias = $local:TimezoneBias.Replace('-', '+') # flip the offset value from negative to positive
		} else {
			$local:TimezoneBias = '-' + $local:TimezoneBias
		}
		Add-Member -InputObject $script:ScriptInfo -MemberType NoteProperty -Name 'Path' -Value $(Split-Path -Path $ScriptInfo.FullPath -Parent) #-Description 'The path/folder/directory containing the script file'
		Add-Member -InputObject $script:ScriptInfo -MemberType NoteProperty -Name 'Name' -Value $(Split-Path -Path $ScriptInfo.FullPath -Leaf) #-Description 'The name and extension of the script file'
		Add-Member -InputObject $script:ScriptInfo -MemberType NoteProperty -Name 'BaseName' -Value $([System.IO.Path]::GetFileNameWithoutExtension($ScriptInfo.Name)) #-Description 'The name without the extension of the script file'
		Add-Member -InputObject $script:ScriptInfo -MemberType NoteProperty -Name 'LogPath' -Value $($ScriptInfo.Path) #-Description 'The full path/folder/directory, name, and extension script file with log extension'
		Add-Member -InputObject $script:ScriptInfo -MemberType NoteProperty -Name 'LogFile' -Value $($ScriptInfo.Path + '\' + $ScriptInfo.BaseName + '.log') #-Description 'The full path/folder/directory, name, and extension script file with log extension'
		Add-Member -InputObject $script:ScriptInfo -MemberType NoteProperty -Name 'LogFullPath' -Value $ScriptInfo.LogFile #-Description 'The full path/folder/directory, name, and extension script file with log extension'
		Add-Member -InputObject $script:ScriptInfo -MemberType NoteProperty -Name 'LibraryFullPath' -Value $FunctionLibrary #-Description 'The full path/folder/directory, name, and extension of the script library (this file)'
		Add-Member -InputObject $script:ScriptInfo -MemberType NoteProperty -Name 'PowerShellVersion' -Value $($PSversionTable.PSversion.toString())
		Add-Member -InputObject $script:ScriptInfo -MemberType NoteProperty -Name 'TimezoneBias' -Value $TimezoneBias
	}
	Write-Verbose -Message "End Function: $(Get-CurrentFunctionName)"
}
Function Write-LogMessage {
	#.Synopsis Write a log entry in CMtrace format
	#.Notes
	#	CMTrace time must be formatted as HH:mm:ss.fff-### to support both CMTrace.exe and Configuration Manager Support Center Log Viewer
	#.Example  Write-LogMessage -LogFile $LogFile
	#.Example  Write-LogMessage -Message "This is a normal message" -LogFile $LogFile -Console
	#.Example  Write-LogMessage -Message "This is a normal message" -ErrorMessage $Error -LogFile $LogFile -Console
	#.Example  Write-LogMessage -Message "This is a warning" -Type Warn -Component "Test Component" -LogFile $LogFile
	#.Example  Write-LogMessage -Message "This is an Error!" -Type Error -Component "My Component" -LogFile $LogFile
	#.Parameter Message
	#	The message to write
	#.Parameter Type
	#	The type of message Information/Info/1, Warning/Warn/2, Error/3
	#.Parameter Component
	#	The source of the message being logged.  Typically the script name or function name.
	#.Parameter LogFile
	#	The file the message will be logged to
	#.Parameter Console
	#	Display the Message in the console
	Param (
		[Parameter(Mandatory = $true)][string]$Message,
		[Parameter()][ValidateSet('Error', 'Warn', 'Warning', 'Info', 'Information', '1', '2', '3')][string]$Type,
		[Parameter()][string]$Component = $ScriptInfo.BaseName,
		[Parameter()][string]$LogFile = $ScriptInfo.LogFile,
		[Parameter()][switch]$Console
	)
	If ($LogFile.Length -lt 6) { $LogFile = "$env:SystemRoot\Logs\Script.log" } #Must not be null
	If ([string]::IsNullOrEmpty($Component)) { $Component = ' ' } #Must not be null
	If ([string]::IsNullOrEmpty($Message)) { $Message = ' ' } #Must not be null
	Switch ($Type) {
		{ @('3', 'Error', 'Err') -contains $_ } { $intType = 3; $Type = 'Error' } #3 = Error (red)
		{ @('2', 'Warn', 'Warning') -contains $_ } { $intType = 2; $Type = 'Warning' } #2 = Warning (yellow)
		Default { $intType = 1; $Type = 'Information' } #1 = Normal
	}
	If ($Console) {
		#write to console if enabled
		Switch ($Type) {
			'Information' { Write-Output $Message }
			'Warning' { Write-Warning $Message }
			'Error' { Write-Error $Message }
		}
	} Else {
		Write-Verbose -Message "Write-LogMessage: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`t$env:ComputerName `t$Type `t$Component `n   $Message"
	}
	#write message
	try {
		"<![LOG[$Message]LOG]!><time=`"$(Get-Date -Format HH:mm:ss.fff)$($ScriptInfo.TimezoneBias)`" date=`"$(Get-Date -Format "MM-dd-yyyy")`" component=`"$Component`" context=`"`" type=`"$intType`" thread=`"$PID`" file=`"$Component`">" | Out-File -Append -Encoding UTF8 -FilePath $LogFile
	} catch { Write-Error "Failed to write to the CMTrace style log file [$LogFile]" }
}
Function Start-Script ([string]$LogFile = $script:LogFile, [switch]$ArchiveExistingLogFile) {
	#Required: Get-ScriptInfo(), Write-LogMessage()
	#if the ScriptLog is undefined set to script ScriptLog
	#if the ScriptLog is still undefined set to <WindowsDir>\Logs\Script.log
	Write-Verbose -Message "Start Function: (Get-CurrentFunctionName) -LogFile [$LogFile]"
	If (-not($ScriptInfo -is [object])) {
		Get-ScriptInfo -FullPath $(If (Test-Path -LiteralPath 'variable:HostInvocation') { $HostInvocation.MyCommand.Definition } Else { $MyInvocation.MyCommand.Definition })
	}
	If ([string]::IsNullOrEmpty($LogFile)) {
		If ([string]::IsNullOrEmpty($ScriptInfo.LogFile)) {
			$ScriptInfo.LogFile = "$env:WinDir\Logs\Scripts.log"
			$ScriptInfo.LogFullPath = "$env:WinDir\Logs\Scripts.log"
		}
	} Else {
		$ScriptInfo.LogFile = $LogFile
		$ScriptInfo.LogFullPath = $LogFile
	}
	$ScriptInfo.LogPath = Split-Path -Path $LogFile -Parent
	#if the LogFile folder does not exist, create the folder
	If (-not(Test-Path -Path $ScriptInfo.LogPath -PathType Container -ErrorAction SilentlyContinue)) { New-Item -Path $ScriptInfo.LogPath -ItemType Directory -Force }
	#write initial message
	Write-Verbose "Logging to $($ScriptInfo.LogFile)"
	If ($ArchiveExistingLogFile) { If (Get-command 'Backup-LogFile' -ErrorAction SilentlyContinue) { Backup-LogFile -LogFile $($ScriptInfo.LogFile) -Force } }
	Else { If (Get-Command 'Backup-LogFile' -ErrorAction SilentlyContinue) { Backup-LogFile -LogFile $($ScriptInfo.LogFile) } }
	Write-LogMessage -Message "==================== Starting script [$($script:ScriptInfo.FullPath)] at $($script:ScriptInfo.StartTime.ToString('F')) ===================="
	Write-LogMessage -Message "Logging to file [$LogFile]"
	If ($WhatIfPreference) { Write-LogMessage -Message "     ========== Running with WhatIf.  NO ACTUAL CHANGES are expected to be made! ==========" -Type Warn }
	Write-LogMessage -Message "End Function: $(Get-CurrentFunctionName)"
}
Function Stop-Script ($ReturnCode) {
	#Required: Get-ScriptInfo(), Write-LogMessage()
	Write-LogMessage -Message "Start Function: $(Get-CurrentFunctionName) -ReturnCode [$ReturnCode]"
	If ($WhatIfPreference) { Write-LogMessage -Message "     ========== Running with WhatIf.  NO ACTUAL CHANGES are expected to be made! ==========" -Type Warn }
	Write-LogMessage -Message "Exiting with return code $ReturnCode"
	$ScriptInfo.EndTime = $(Get-Date) #-Description 'The date and time the script completed'
	$ScriptTimeSpan = New-TimeSpan -Start $ScriptInfo.StartTime -End $ScriptInfo.EndTime #New-TimeSpan -seconds $(($(Get-Date)-$StartTime).TotalSeconds)
	Write-LogMessage -Message "Script Completed in $([math]::Round($ScriptTimeSpan.TotalSeconds)) seconds, started at $(Get-Date $ScriptInfo.StartTime -Format 'yyyy/MM/dd hh:mm:ss'), and ended at $(Get-Date $ScriptInfo.EndTime -Format 'yyyy/MM/dd hh:mm:ss')" -Console
	#Write-LogMessage -Message "End Function: $(Get-CurrentFunctionName)"
	Write-LogMessage -Message "==================== Completed script [$($ScriptInfo.FullPath)] at $(Get-Date -Format 'F') ====================" -Console
	Write-Verbose -Message $('ScriptInfo Custom PSObject...' + $($ScriptInfo | Format-List | Out-String))
	Exit $ReturnCode
}

Function Set-CleanManagerSettings {
	#.SYNOPSIS
	#	Update registry with Disk Cleanup Manager settings
	#.LINK
	#   https://gregramsey.net/2014/05/14/automating-the-disk-cleanup-utility/
	param (
		[string]$StateFlagsID = '2020', #any value
		[string[]]$VolumeCaches #array of items to clean
	)
	Write-LogMessage -Message "Start Function: $(Get-CurrentFunctionName) -StateFlagsID [$StateFlagsID]"
	$RegPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
	If ($VolumeCaches -eq $true) {
		Write-LogMessage -Message 'Getting all supported items'
		$VolumeCaches = @((Get-ChildItem -Path "HKLM:\$RegPath").Name).Replace("HKEY_LOCAL_MACHINE\$RegPath\", '')
	} ElseIf ($VolumeCaches.Count -lt 1) {
		Write-LogMessage -Message 'Getting items generally safe for corporate computers'
		$VolumeCaches = 'Active Setup Temp Folders',
			'BranchCache',
			'Content Indexer Cleaner',
			'Delivery Optimization Files',
			'D3D Shader Cache',
			'Device Driver Packages',
			'Downloaded Program Files',
			'GameNewsFiles', 'GameStatisticsFiles', 'GameUpdateFiles',
			'Internet Cache Files',
			'Memory Dump Files',
			'Offline Pages Files',
			'Old ChkDsk Files',
			'Previous Installations',
			'RetailDemo Offline Content',
			'Service Pack Cleanup',
			'Setup Log Files',
			'System error memory dump files', 'System error minidump files',
			'Temporary Files', 'Temporary Setup Files', 'Temporary Sync Files',
			'Thumbnail Cache',
			'Update Cleanup',
			'Upgrade Discarded Files',
			'Windows Defender',
			'Windows Error Reporting Archive Files', 'Windows Error Reporting Files', 'Windows Error Reporting Queue Files', 'Windows Error Reporting System Archive Files', 'Windows Error Reporting System Queue Files', 'Windows Error Reporting Temp Files',
			'Windows ESD installation files',
			'Windows Upgrade Log Files'
	}
	Write-LogMessage -Message "Setting values for HKLM:\$RegPath\ <NAME> \StateFlags$StateFlagsID" -Component $MyInvocation.MyCommand
	((Get-ChildItem -Path "HKLM:\$RegPath").Name).Replace("HKEY_LOCAL_MACHINE\$RegPath\", '') | ForEach-Object {
		If ($VolumeCaches -contains $_) {
			$VolumeCacheValue = 2
		} Else {
			$VolumeCacheValue = 0
		}
		Write-LogMessage -Message "Setting $_ to $VolumeCacheValue" -Component $MyInvocation.MyCommand
		If (-not(Test-Path -Path "HKLM:\$RegPath\$_")) {
			New-Item -Path "HKLM:\$RegPath\$_" -Force
		}
		try {
			Set-ItemProperty -Path "HKLM:\$RegPath\$_" -Name "StateFlags$StateFlagsID" -Type DWORD -Value $VolumeCacheValue -Force -ErrorAction Stop
		} catch {
			Write-LogMessage -Message "FAILED setting $_ to $VolumeCacheValue with error $($error[0])" -Component $MyInvocation.MyCommand
		}
	}
	Write-LogMessage -Message "End Function: $(Get-CurrentFunctionName)"
}
Function Get-CleanManagerSettings ([string]$StateFlagsID = "2020") {
	Write-LogMessage -Message "Start Function: $(Get-CurrentFunctionName) -StateFlagsID [$StateFlagsID]"
	$RegPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
	Write-LogMessage -Message "Values for HKLM:\$RegPath\ <NAME> \StateFlags$StateFlagsID" -Component $MyInvocation.MyCommand -Verbose
	$VolumeCacheValues = @{}
	((Get-ChildItem -Path "HKLM:\$RegPath").Name).Replace("HKEY_LOCAL_MACHINE\$RegPath\", '') | ForEach-Object {
		$VolumeCacheValues.add("$_", (Get-ItemProperty -Path "HKLM:\$RegPath\$_" -Name "StateFlags$StateFlagsID" -ErrorAction SilentlyContinue)."StateFlags$StateFlagsID")
	}
	Write-LogMessage -Message "End Function: $(Get-CurrentFunctionName)"
	Return $VolumeCacheValues.GetEnumerator() | Sort-Object Name
}
Function Remove-CleanManagerSettings ([string]$StateFlagsID = "2020") {
	Write-LogMessage -Message "Start Function: $(Get-CurrentFunctionName) -StateFlagsID [$StateFlagsID]"
	$RegPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
	Write-LogMessage -Message "Removing HKLM:\$RegPath\ <NAME> \StateFlags$StateFlagsID" -Component $MyInvocation.MyCommand
	((Get-ChildItem -Path "HKLM:\$RegPath").Name).Replace("HKEY_LOCAL_MACHINE\$RegPath\", '') | ForEach-Object {
		try {
			Remove-ItemProperty -Path "HKLM:\$RegPath\$_" -Name "StateFlags$StateFlagsID" -ErrorAction SilentlyContinue
		} catch {
			Write-LogMessage -Message "FAILED removing HKLM:\$RegPath\$_\StateFlags$StateFlagsID" -Component $MyInvocation.MyCommand
		}
	}
	Write-LogMessage -Message "End Function: $(Get-CurrentFunctionName)"
}
Function Start-CleanManager ([string]$StateFlagsID = $(Get-Date -f 'HHmm'), [string[]]$VolumeCaches, [int]$WaitSeconds = 300) {
	Write-LogMessage -Message "Start Function: $(Get-CurrentFunctionName) -StateFlagsID [$StateFlagsID] -Wait [$Wait]"
	If (-not($PSBoundParameters.ContainsKey('VolumeCaches'))) { #set safe defaults
		$VolumeCaches = 'D3D Shader Cache',
		'Downloaded Program Files',
		'GameNewsFiles', 'GameStatisticsFiles', 'GameUpdateFiles',
		'Internet Cache Files',
		'Memory Dump Files',
		'Offline Pages Files',
		'Old ChkDsk Files',
		'Previous Installations',
		'RetailDemo Offline Content',
		'Service Pack Cleanup',
		'Setup Log Files',
		'System error memory dump files', 'System error minidump files',
		'Temporary Files', 'Temporary Setup Files', 'Temporary Sync Files',
		'Update Cleanup',
		'Upgrade Discarded Files',
		'Windows Defender',
		'Windows Error Reporting Archive Files', 'Windows Error Reporting Files', 'Windows Error Reporting Queue Files', 'Windows Error Reporting System Archive Files', 'Windows Error Reporting System Queue Files', 'Windows Error Reporting Temp Files',
		'Windows ESD installation files',
		'Windows Upgrade Log Files'
	}
	Write-LogMessage -Message "Preparing to run Disk Cleanup Manager against drive $env:SystemDrive including these options [$($VolumeCaches -join ',')]."
	Remove-CleanManagerSettings -StateFlagsID $StateFlagsID
	Set-CleanManagerSettings -StateFlagsID $StateFlagsID -VolumeCaches $VolumeCaches
	#Get-CleanManagerSettings -StateFlagsID $StateFlagsID | Format-Table -AutoSize

	$ArgumentList = "/sagerun:$StateFlagsID", "/d $env:SystemDrive"
	Write-LogMessage -Message "Running cleanmgr.exe $ArgumentList" -Component $MyInvocation.MyCommand
	#cleanmgr.exe /AUTOCLEAN
	#cleanmgr.exe /LowDisk
	#cleanmgr.exe /VeryLowDisk
	$Process = Start-Process -FilePath "$env:SystemRoot\System32\CleanMgr.exe" -ArgumentList $ArgumentList -Verb RunAs -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
	If ($WaitSeconds -gt 0) { #Create a progress bar to show that we are waiting for the processes to complete
		$iCounter = 1
		do {
			Write-Progress -Activity "Running Disk Cleanup Manager" -Status "Waiting until $(Get-Date -Date (Get-Date).AddSeconds($WaitSeconds) -Format t) for completion" -PercentComplete $iCounter
			Start-Sleep 5
			If ($iCounter -lt 99) { $iCounter++ } else { $iCounter = 5 }
			$ProcessTimeSpan = New-TimeSpan -Start $Process.StartTime -End $(Get-Date)
			If ($ProcessTimeSpan.TotalSeconds -gt $WaitSeconds) {
				Stop-Process -Force -Id $Process.Id -ErrorAction SilentlyContinue
				Stop-Process -Force -Name DISMHOST -ErrorAction SilentlyContinue
			}
		} while ($Process.HasExited -eq $false)
	}
	#$UpdateCleanupSuccessful = $false
	#if (Test-Path $env:SystemRoot\Logs\CBS\DeepClean.log) {
	#	$UpdateCleanupSuccessful = Select-String -Path $env:SystemRoot\Logs\CBS\DeepClean.log -Pattern 'Total size of superseded packages:' -Quiet
	#}
	Remove-CleanManagerSettings -StateFlagsID $StateFlagsID
	Write-LogMessage -Message "End Function: $(Get-CurrentFunctionName)"
}
Function Get-CriticalPaths {
	Write-LogMessage -Message "Start Function: $(Get-CurrentFunctionName)"
	$PathList = @()
	$PathList += $env:SystemDrive
	$PathList += $env:SystemRoot
	$PathList += Join-Path -Path $env:SystemRoot -ChildPath 'System32'
	$PathList += Join-Path -Path $env:SystemRoot -ChildPath 'SysWOW64'
	$PathList += $env:ProgramData
	$PathList += $env:ProgramFiles
	$PathList += ${env:ProgramFiles(x86)}
	$PathList += $env:ProgramW6432
	$PathList += $env:CommonProgramW6432
	$PathList += $env:ALLUSERSPROFILE
	$PathList += $env:HOMEDRIVE
	$PathList += $env:HOMEPATH
	$PathList += $env:HOMEDRIVE + $env:HOMEPATH
	$PathList += $env:USERPROFILE
	$PathList += Split-Path -Path $env:USERPROFILE -Parent
	Write-LogMessage -Message "End Function: $(Get-CurrentFunctionName)"
	Return $PathList
}
Function Remove-File {
	#.Synopsis
	#   Remove a System and/or In-Use File
	#.Description
	#   attempt to delete the file.  If fails, take ownership, reset security and try again.
	#	ENHANCEMENT: If delete fails, set to delete on restart (PendMovesEx)
	param (
		[Parameter(Mandatory = $true)][String]$FilePath,
		[Parameter()][int]$CreatedMoreThanDaysAgo = 9999
	)
	If (Test-Path -Path $FilePath -PathType Leaf -ErrorAction SilentlyContinue) {
		$File = Get-Item -Path $FilePath -ErrorAction SilentlyContinue
		If ($File.CreationTime -gt $(Get-Date).AddDays(-$CreatedMoreThanDaysAgo)) {
			Write-LogMessage -Message "Not attempting to remove file [$FilePath].  It was created less than $CreatedMoreThanDaysAgo days ago."
		} Else {
			Write-LogMessage -Message "Attempting to remove [$([math]::Round($File.length/1mb,1)) MB] file [$FilePath]"
			try {
				Remove-Item -Path $FilePath -Force -ErrorAction Stop
				Write-LogMessage -Message "Removed file [$FilePath]"
			} Catch {
				Try {
					#take ownership
					Start-Process -FilePath "$env:SystemRoot\System32\takeown.exe" -ArgumentList '/F', "`"$FilePath`"", '/R', '/A', '/D', 'Y' -Wait -Verb RunAs -ErrorAction Stop
					Start-Process -FilePath "$env:SystemRoot\System32\icacls.exe" -ArgumentList "`"$FilePath`"", '/T', '/grant', 'administrators:F' -Wait -Verb RunAs -ErrorAction Stop
					Write-LogMessage -Message "Took ownership of file [$FilePath]"
					Remove-Item -Path $FilePath -Force -ErrorAction Stop
					Write-LogMessage -Message "Removed file [$FilePath]"
				} Catch {
					Write-LogMessage -Message "Failed to remove file [$FilePath]" -Type Warn
				}
			}
		}
	} Else {
		Write-LogMessage -Message "Not attempting to remove nonexistent file [$FilePath]"
	}
}
Function Remove-Directory {
	param ( [Parameter(Mandatory = $true)][ValidateLength(4, 255)][String]$Path )
	#	ENHANCEMENT: If delete fails, set to delete on restart (PendMovesEx)
	If ($Path -contains $(Get-CriticalPaths)) {
		Write-LogMessage -Message "WARNING Will not delete Critical or System Directory [$Path]" -Type Warn
	} ElseIf ($Path -notlike "$env:SystemDrive*") {
		Write-LogMessage -Message "WARNING Will not delete non-SystemDrive file [$Path]" -Type Warn
	} Else {
		If (Test-Path -Path $Path -PathType Container) {
			$FolderSize = Get-ChildItem "$Path" -Recurse -Force | Measure-Object -Property Length -Sum | Select-Object -ExpandProperty Sum
			Write-LogMessage -Message "Attempting to remove [$([math]::Round($FolderSize/1mb,1)) MB] directory [$Path]"
			try {
				Remove-Item -Path "$Path" -Recurse -Force -ErrorAction Stop
				Write-LogMessage -Message "Removed directory [$Path]"
			} Catch {
				try {
					Write-LogMessage -Message "Taking ownership of directory [$Path]"
					Start-Process -FilePath "$env:WinDir\System32\takeown.exe" -ArgumentList '/F', "`"$Path`"", '/R', '/A', '/D', 'Y' -Wait -Verb RunAs -ErrorAction Stop
					Start-Process -FilePath "$env:WinDir\System32\icacls.exe" -ArgumentList "`"$Path`"", '/T', '/grant', 'administrators:F' -Wait -Verb RunAs -ErrorAction Stop
					Remove-Item -Path "$Path" -Force -ErrorAction SilentlyContinue
					Write-LogMessage -Message "Removed directory [$Path]"
				} catch {
					Write-LogMessage -Message "Failed to remove directory [$Path]" -Type Warn
				}
			}
		} Else {
			Write-LogMessage -Message "Not attempting to remove nonexistent directory [$Path]"
		}
	}
	#Write-LogMessage -Message "End Function: $($MyInvocation.MyCommand)"
}
Function Remove-DirectoryContents {
	#Synopsis
	#   Remove files from a folder/directory/path
	#   Folders are ignored
	#ENHANCEMENT: Handle in-use files
	param (
		[Parameter(Mandatory = $true)][ValidateLength(4, 255)][String]$Path,
		[Parameter()][ValidateLength(1, 255)][String[]]$Exclude,
		[Parameter()][int]$CreatedMoreThanDaysAgo = 8
	)
	If ($Path -contains $(Get-CriticalPaths)) {
		Write-LogMessage -Message "WARNING Will not delete contents from Critical or System Directory [$Path]" -Type Warn
	} ElseIf ($Path -notlike "$env:SystemDrive*") {
		Write-LogMessage -Message "WARNING Will not delete contents from non-SystemDrive file [$Path]" -Type Warn
	} Else {
		If (Test-Path -Path $Path -PathType Container) {
			Write-LogMessage -Message "Removing files created more than $CreatedMoreThanDaysAgo days ago from directory [$Path]"
			$FileList = Get-ChildItem -Path $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { ($_.CreationTime -lt $(Get-Date).AddDays(-$CreatedMoreThanDaysAgo) -and $_.PSIsContainer -eq $false) }
			ForEach ($File in $FileList) {
				If ($Exclude -contains $File.Name) {
					Write-LogMessage -Message "[$($File.Name)] is excluded from removal" -Type Warn
				} Else {
					Remove-File -FilePath $File.FullName -CreatedMoreThanDaysAgo $CreatedMoreThanDaysAgo
				}
			}
			Write-LogMessage -Message "Removed $i files from [$Path]" -Type Warn
		} Else {
			Write-LogMessage -Message "Not attempting to remove files from nonexistent directory [$Path]"
		}
	}
}
Function Remove-CCMCacheContent {
	#.SYNOPSIS
	#   Purge ConfigMgr Client Cache items not referenced in X days
	#https://sccmf12twice.com/2018/12/keeping-the-sccm-cache-clean-with-dcm
	#https://sccm-zone.com/deleting-the-sccm-cache-the-right-way-3c1de8dc4b48
	#https://gregramsey.net/2015/11/17/tidy-cache-clean-up-old-ccmcache/
	#and StorageCleanUp\Remove-CCMCacheSoftwareUpdateContent.ps1 from GARYTOWN.com WaaS_Scripts
	#ENHANCEMENT: Support ignoring Persistent content unless $Force is specified
	param (
		[Parameter()][ValidateSet('All', 'SoftwareUpdate', 'Application', 'Package')][string]$Type = 'SoftwareUpdate',
		[Parameter()][int16]$ReferencedDaysAgo = 5
	)
	Write-LogMessage -Message "Start Function: $(Get-CurrentFunctionName)"
	try {
		$UIResourceMgr = New-Object -ComObject UIResource.UIResourceMgr
		$CMCacheObjects = $UIResourceMgr.GetCacheInfo()
		Switch ($Type) {
			'SoftwareUpdate' {
				#Software Update content has a length of 36, Packages are 9, Applications are Content_*
				$CCMCacheItems = $CMCacheObjects.GetCacheElements() | Where-Object { ([datetime]$_.LastReferenceTime -lt (Get-Date).AddDays(-$ReferencedDaysAgo)) -and ($_.ContentID | Select-String -Pattern '^[\dA-F]{8}-(?:[\dA-F]{4}-){3}[\dA-F]{12}$') }
				Write-LogMessage -Message "Found $($CCMCacheItems.Length) ConfigMgr client cache Software Update items totaling [$([math]::Round(($CCMCacheItems | Measure-Object -Property ContentSize -Sum | Select-Object -ExpandProperty Sum)/1KB,1)) MB]"
			}
			'Application' {
				#Software Update content has a length of 36, Packages are 9, Applications are Content_*
				$CCMCacheItems = $CMCacheObjects.GetCacheElements() | Where-Object { ([datetime]$_.LastReferenceTime -lt (Get-Date).AddDays(-$ReferencedDaysAgo)) -and ($_.ContentID -like 'Content_*') }
				Write-LogMessage -Message "Found $($CCMCacheItems.Length) ConfigMgr client cache Application items totaling [$([math]::Round(($CCMCacheItems | Measure-Object -Property ContentSize -Sum | Select-Object -ExpandProperty Sum)/1KB,1)) MB]"
			}
			'Package' {
				#Software Update content has a length of 36, Packages are 9, Applications are Content_*
				$CCMCacheItems = $CMCacheObjects.GetCacheElements() | Where-Object { ($_.ContentId).ToString().Length -eq 8 -and [datetime]$_.LastReferenceTime -lt (Get-Date).AddDays(-$ReferencedDaysAgo) }
				Write-LogMessage -Message "Found $($CCMCacheItems.Length) ConfigMgr client cache Package items totaling [$([math]::Round(($CCMCacheItems | Measure-Object -Property ContentSize -Sum | Select-Object -ExpandProperty Sum)/1KB,1)) MB]"
			}
			'All' {
				$CCMCacheItems = $CMCacheObjects.GetCacheElements() | Where-Object { ([datetime]$_.LastReferenceTime -lt (Get-Date).AddDays(-$ReferencedDaysAgo)) }
				Write-LogMessage -Message "Found $($CCMCacheSoftwareUpdates.Length) ConfigMgr client cache items totaling [$([math]::Round(($CCMCacheItems | Measure-Object -Property ContentSize -Sum | Select-Object -ExpandProperty Sum)/1KB,1)) MB]"
			}
		}
		ForEach ($CacheElement in $CCMCacheItems) {
			Write-LogMessage -Message "Found ConfigMgr client cache content in folder [$($CacheElement.Location)] Last referenced [$($CacheElement.LastReferenceTime)] totaling [$([math]::Round(($CacheElement.ContentSize)/1KB,1)) MB]"
			try {
				$CMCacheObjects.DeleteCacheElement($CacheElement.CacheElementID)
				Write-LogMessage -Message "Removed ConfigMgr client cache ID $($CacheElement.CacheElementID)"
			} catch {
				Write-LogMessage -Message "Could not remove ConfigMgr client cache ID $($CacheElement.CacheElementID)"
			}
		}
	} catch {
		Write-LogMessage -Message "Could not connect to ConfigMgr client UI Resource Manager" -Type Warn
	}
	Write-LogMessage -Message "End Function: $(Get-CurrentFunctionName)"
}
Function Remove-WUAFiles {
	param (
		[Parameter()][string[]]$Type = 'Downloads',
		[Parameter()][int16]$CreatedMoreThanDaysAgo = 8
	)
	Write-LogMessage -Message "Start Function: $(Get-CurrentFunctionName) -Type [$Type] -CreatedMoreThanDaysAgo [$CreatedMoreThanDaysAgo]"
	$WUAservice = Get-Service -Name wuauserv
	If ($WUAservice.Status -eq 'Running') {
		Stop-Service -Name wuauserv
		Write-LogMessage -Message "Stopping Windows Update Agent long enough to delete aged downloaded files"
	}
	If ($Type -contains 'Downloads') {
		Remove-DirectoryContents -CreatedMoreThanDaysAgo $CreatedMoreThanDaysAgo -Path (Join-Path -Path $env:SystemRoot -ChildPath 'SoftwareDistribution\Download')
	}
	If ($Type -contains 'Logs') {
		Remove-DirectoryContents -CreatedMoreThanDaysAgo 0 -Path (Join-Path -Path $env:SystemRoot -ChildPath 'SoftwareDistribution\DataStore\Logs')
		Remove-File -CreatedMoreThanDaysAgo 0 -FilePath (Join-Path -Path $env:SystemRoot -ChildPath 'SoftwareDistribution\ReportingEvents.log')
	}
	If ($Type -contains 'EDB') {
		Remove-File -CreatedMoreThanDaysAgo 0 -FilePath (Join-Path -Path $env:SystemRoot -ChildPath 'SoftwareDistribution\DataStore\DataStore.edb')
	}
	If ($WUAservice.Status -eq 'Running') {
		Start-Service -Name wuauserv
	}
	Write-LogMessage -Message "End Function: $(Get-CurrentFunctionName)"
}
Function Disable-WindowsHibernation {
	Write-LogMessage -Message "Start Function: $(Get-CurrentFunctionName)"
	$File = (Join-Path -Path $env:SystemDrive -ChildPath 'hiberfil.sys')
	If (Test-Path -Path $File -PathType Leaf) {
		$script:HibernationEnabled = $true
		try {
			Start-Process -FilePath (Join-Path -Path $env:SystemRoot -ChildPath 'System32\powercfg.exe') -ArgumentList '-h OFF' -Wait -ErrorAction Stop -NoNewWindow -Verb RunAs
			Write-LogMessage -Message "Disabling Windows Hibernation and deleting the file [$File]"
		} catch {
			Write-LogMessage -Message "WARNING: Failed disabling Windows Hibernation and deleting the file [$File]" -Type Warn
		}
	} Else {
		$script:HibernationEnabled = $false
		Write-LogMessage -Message "Windows Hibernation is not enabled.  Nothing to do."
	}
	Write-LogMessage -Message "End Function: $(Get-CurrentFunctionName)"
}
Function Enable-WindowsHibernation {
	Write-LogMessage -Message "Start Function: $(Get-CurrentFunctionName)"
	try {
		Start-Process -FilePath (Join-Path -Path $env:SystemRoot -ChildPath 'System32\powercfg.exe') -ArgumentList '-h ON' -Wait -ErrorAction Stop -NoNewWindow -Verb RunAs
		Write-LogMessage -Message "Enabled Windows Hibernation"
	} catch {
		Write-LogMessage -Message "WARNING: Failed enabling Windows Hibernation" -Type Warn
	}
	Write-LogMessage -Message "End Function: $(Get-CurrentFunctionName)"
}
Function Compress-NTFSFolder ([string[]]$PathList) {
	Write-LogMessage -Message "Start Function: $(Get-CurrentFunctionName)"
	If ([string]::IsNullOrEmpty($PathList)) {
		$PathList = @()
		$PathList += Join-Path -Path $env:SystemRoot -ChildPath 'Inf'
		$PathList += Join-Path -Path $env:SystemRoot -ChildPath 'Installer'
		$PathList += Join-Path -Path $env:SystemRoot -ChildPath 'Panther'
		$PathList += Join-Path -Path $env:SystemRoot -ChildPath 'Logs'
		$PathList += Join-Path -Path $env:SystemRoot -ChildPath 'CCM\Logs'
		$PathList += Join-Path -Path $env:SystemRoot -ChildPath 'CCMSetup\Logs'
		$PathList += Join-Path -Path $env:SystemDrive -ChildPath 'Drivers'
		$PathList += Join-Path -Path $env:SystemDrive -ChildPath 'Inetpub\Logs\LogFiles'
	}
	ForEach ($Path in $PathList) {
		If (Test-Path -Path $Path -PathType Container) {
			Write-LogMessage -Message "Enabling NTFS compression for directory [$Path]"
			Start-Process -FilePath (Join-Path -Path $env:SystemRoot -ChildPath 'System32\compact.exe') -ArgumentList '/c', '/q', '/i', "/s:`"$Path`"" -Wait -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue -Verb RunAs
		}
	}
	#ENHANCEMENT: Compress $env:SystemDrive\<files> which do not have hidden or system attributes
	#ENHANCEMENT: Compress $env:SystemDrive\<folders> excluding the defaults of "Hyper-V", PerfLogs, "Program Files", "Program Files (x86)", "Users", "Windows", "InetPub"
	Write-LogMessage -Message "End Function: $(Get-CurrentFunctionName)"
}
Function Get-FreeMB {
	Return [int](((Get-WmiObject -Namespace 'root\CIMv2' -Class Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -Property FreeSpace).FreeSpace) / 1024 / 1024)
}
Function Test-ShouldContinue {
	If ($MinimumFreeMB -eq 0) { $MinimumFreeMB = [int32]::MaxValue }
	If ((Get-FreeMB) -lt $MinimumFreeMB) {
		Return $true
	} Else {
		Return $false
	}
}
################################################################################
################################################################################
#endregion ######################### Functions #################################

#region ############# Initialize ############################################### #BOOKMARK: Script Initialize
$ScriptStartTime = $(Get-Date) #-Description 'The date and time the script completed'

#Detect process elevation / process is running with administrative rights:
$script:User = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$script:UserPrincipal = New-Object System.Security.Principal.WindowsPrincipal($script:User)
$script:AdminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator
$script:RunAsAdmin = $UserPrincipal.IsInRole($script:AdminRole)
If (-not($script:RunAsAdmin)) {
	Write-Error 'Script is not running elevated, which is required. Restart the script from an elevated prompt.'
	Exit 5 #Access denied
}

# Get the current script's full path and file name
If ($PSise) { $script:ScriptFile = $PSise.CurrentFile.FullPath }
ElseIf (Test-Path -LiteralPath 'variable:HostInvocation') { $script:ScriptFile = $HostInvocation.MyCommand.Definition }
Else { $script:ScriptFile = $MyInvocation.MyCommand.Definition }
$script:ScriptPath = $(Split-Path $script:ScriptFile -Parent)
$script:ScriptName = $(Split-Path $script:ScriptFile -Leaf)

If ([string]::IsNullOrEmpty($script:LogFile)) {
	If (Test-Path -Path "$env:SystemRoot\CCM\Logs") {
		$script:LogFile = "$env:SystemRoot\CCM\Logs\$([System.IO.Path]::GetFileNameWithoutExtension($script:ScriptName)).log" #"$env:WinDir\Logs\CCM\<ScriptName>.log"
	} Else {
		$script:LogFile = "$env:SystemRoot\Logs\$([System.IO.Path]::GetFileNameWithoutExtension($script:ScriptName)).log" #"$env:WinDir\Logs\<ScriptName>.log"
	}
}
Start-Script

#endregion ######################### Initialization ############################

#region ############# Main Script ############################################## #BOOKMARK: Script Main
Write-LogMessage -Message "Attempting to get $('{0:n0}' -f $MinimumFreeMB) MB free on the $env:SystemDrive drive"
$StartFreeMB = Get-FreeMB
Write-LogMessage -Message "$('{0:n0}' -f $StartFreeMB) MB of free disk space exists before cleanup"
Write-LogMessage -Message "When deleting temp files, only files created more than $FileAgeInDays days age should be removed"
Write-LogMessage -Message "When deleting user profiles, only profiles not used in $ProfileAgeInDays days should be removed"

#Cleanup items regardless of free space

#Purge Windows memory dumps.  This is also handled in Disk Cleanup Manager
Remove-File -FilePath (Join-Path -Path $env:SystemRoot -ChildPath 'memory.dmp')
Remove-Directory -Path (Join-Path -Path $env:SystemRoot -ChildPath 'minidump')

#Purge System temp / Windows\Temp files
Remove-DirectoryContents -CreatedMoreThanDaysAgo $FileAgeInDays $([Environment]::GetEnvironmentVariable('TEMP', 'Machine'))
If ($([Environment]::GetEnvironmentVariable('TEMP', 'Machine')) -ne (Join-Path -Path $env:SystemRoot -ChildPath 'Temp')) {
	Remove-DirectoryContents -CreatedMoreThanDaysAgo $FileAgeInDays -Path (Join-Path -Path $env:SystemRoot -ChildPath 'Temp')
}

#Purge Windows Update downloads
Remove-WUAFiles -Type 'Downloads' -CreatedMoreThanDaysAgo $FileAgeInDays
Remove-CCMCacheContent -Type SoftwareUpdate -ReferencedDaysAgo 5

#Compress Folders
Compress-NTFSFolder #compact common NTFS folders

###############################################################################
If (-not(Test-ShouldContinue)) { Write-LogMessage 'More than the minimum required disk space exists.  Exiting'; Exit 0 }

If (Test-ShouldContinue) { #Purge ConfigMgr Client Package Cache items not referenced in X days
	Remove-CCMCacheContent -Type Package -ReferencedDaysAgo 30
}
If (Test-ShouldContinue) { #Purge ConfigMgr Client Application Cache items not referenced in X days
	Remove-CCMCacheContent -Type Application -ReferencedDaysAgo 30
}
If (Test-ShouldContinue) { #Purge Windows upgrade temp and backup folders.  This is also handled in Disk Cleanup Manager
	Remove-Directory -Path (Join-Path -Path $env:SystemDrive -ChildPath '$INPLACE.~TR')
	Remove-Directory -Path (Join-Path -Path $env:SystemDrive -ChildPath '$Windows.~BT')
	Remove-Directory -Path (Join-Path -Path $env:SystemDrive -ChildPath '$Windows.~LS')
	Remove-Directory -Path (Join-Path -Path $env:SystemDrive -ChildPath '$Windows.~WS')
	Remove-Directory -Path (Join-Path -Path $env:SystemDrive -ChildPath '$Windows.~Q')
	Remove-Directory -Path (Join-Path -Path $env:SystemDrive -ChildPath '$Windows.~TR')
	Remove-Directory -Path (Join-Path -Path $env:SystemDrive -ChildPath '$Windows.old')
	Remove-Directory -Path (Join-Path -Path $env:SystemDrive -ChildPath 'ESD')
}
If (Test-ShouldContinue) { #Purge Windows Update Agent logs, downloads, and catalog
	Remove-WUAFiles -Type 'EDB','Logs','Downloads' -CreatedMoreThanDaysAgo $FileAgeInDays
}
If (Test-ShouldContinue) { #Purge Component Based Service files
	#.LINK http://powershell.com/cs/blogs/tips/archive/2016/06/01/cleaning-week-deleting-cbs-log-file.aspx
	Stop-Service -Name TrustedInstaller
	#CBS.log, CbsPersist*.cab and DISM.log
	Remove-DirectoryContents -CreatedMoreThanDaysAgo 0 -Path (Join-Path -Path $env:SystemRoot -ChildPath 'Logs\CBS')
	Remove-DirectoryContents -CreatedMoreThanDaysAgo 0 -Path (Join-Path -Path $env:SystemDrive -ChildPath 'CbsTemp')
	Start-Service -Name TrustedInstaller
}
If (Test-ShouldContinue) { #Cleanup User Temp folders: Deletes anything in the Temp folder with creation date over x days ago.
	$UserTempPaths = Get-ChildItem $env:SystemDrive\users\*\AppData\Local\Temp -Force -ErrorAction SilentlyContinue | Where-Object { ($_.PSIsContainer -eq $true) }
	ForEach ($Path in $UserTempPaths) {
		#Remove-DirectoryContents does not delete folders.  We do NOT want to delete the 'LOW' folder
		Remove-DirectoryContents -CreatedMoreThanDaysAgo $FileAgeInDays -Path $Path.FullName
	}
	#ENHANCEMENT: Delete Outlook Temp Folder Files not modified in the last X days
	# Remove items with exclusions # from https://deployhappiness.com/automatic-disk-cleanup-with-group-policy-and-sccm/
	# Remove-Item -Recurse -Force c:\Users\*\AppData\Local\* -Exclude "Microsoft", "Google"
}
If (Test-ShouldContinue) { #Cleanup User Temporary Internet Files
	# Removes all files and folders in user's Temporary Internet Files older then $DaysToDelete
	$UserTempInternetFilesPaths = Get-ChildItem "$env:SystemDrive\users\*\AppData\Local\Microsoft\Windows\Temporary Internet Files\*" -Force -Recurse -ErrorAction SilentlyContinue | Where-Object { ($_.PSIsContainer -eq $true) }
	Write-LogMessage -Message 'Cleanup User Temporary Internet Files'
	ForEach ($Path in $UserTempInternetFilesPaths) {
		Remove-DirectoryContents -CreatedMoreThanDaysAgo $FileAgeInDays -Path $Path.FullName
	}
	#ENHANCEMENT: Purge Microsoft Internet Explorer Temp Files
	#ENHANCEMENT: Purge Microsoft Edge Chromium Temp Files
	#ENHANCEMENT: Purge Google Chrome Temp Files
	#ENHANCEMENT: Purge Mozilla Firefox Temp Files
<#
if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatCache\") {
        Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatCache\*" -Force -Recurse -Verbose -ErrorAction SilentlyContinue
    } else {
            Write-Host "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatCache\ does not exist.                         " -NoNewline -ForegroundColor DarkGray
            Write-Host "[WARNING]" -ForegroundColor DarkYellow -BackgroundColor Black
    }

    ## Cleans up Internet Explorer cache
    if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatUaCache\") {
        Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatUaCache\*" -Force -Recurse -Verbose -ErrorAction SilentlyContinue
    } else {
            Write-Host "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatUaCache\ does not exist.                       " -NoNewline -ForegroundColor DarkGray
            Write-Host "[WARNING]" -ForegroundColor DarkYellow -BackgroundColor Black
    }

    ## Cleans up Internet Cache
    if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Windows\INetCache\") {
        Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Windows\INetCache\*" -Force -Recurse -Verbose -ErrorAction SilentlyContinue
    } else {
            Write-Host "C:\Users\*\AppData\Local\Microsoft\Windows\INetCache\ does not exist.                             " -NoNewline -ForegroundColor DarkGray
            Write-Host "[WARNING]" -ForegroundColor DarkYellow -BackgroundColor Black
    }

    ## Cleans up terminal server cache
    if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Terminal Server Client\Cache\") {
        Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Terminal Server Client\Cache\*" -Force -Recurse -Verbose -ErrorAction SilentlyContinue
    } else {
            Write-Host "C:\Users\*\AppData\Local\Microsoft\Terminal Server Client\Cache\ does not exist.                  " -NoNewline -ForegroundColor DarkGray
            Write-Host "[WARNING]" -ForegroundColor DarkYellow -BackgroundColor Black
    }
#>
}
If (Test-ShouldContinue) {
	Remove-Directory -Path (Join-Path -Path $env:SystemDrive -ChildPath 'Drivers')
}
If (Test-ShouldContinue) {
	Remove-DirectoryContents -CreatedMoreThanDaysAgo 1 -Path (Join-Path -Path $env:SystemRoot -ChildPath 'Prefetch')

	#ENHANCEMENT: Purge Offline Files Remove-Item -Recurse -Force "C:\Windows\CSC\v2.0.6\namespace\*" #Offline Files

	#ENHANCEMENT: Purge Microsoft IIS Logfiles more than X days old
	#See Clean-IIS*.ps1; Cleanup-IIS*.ps1; Clean-INETPub*.ps1; Cleanup-INETPub*.ps1
	#Remove-DirectoryContents -CreatedMoreThanDaysAgo $FileAgeInDays -Path (Join-Path -Path $env:SystemDrive -ChildPath 'IIS....')
}
If (Test-ShouldContinue) { #Delete User Profiles over x days inactive
	<#
	.SYNOPSIS
	Use Delprof2.exe to delete inactive profiles older than X days
	.DESCRIPTION
		StorageCleanUp\ProfileCleanup.ps1 from GARYTOWN.com WaaS_Scripts
		Gets Top Console user from ConfigMgr Client WMI, then runs delprof tool, excluding top console user list,
		and deletes any other inactive accounts based on how many days that you set in the -Days parameter.
		typical arguments
			l   List only, do not delete (what-if mode) - Set by default
			u   Unattended (no confirmation) - Recommended to leave logs
			q   Quiet (no output and no confirmation)
	.LINK
		https://garytown.com
		https://helgeklein.com/free-tools/delprof2-user-profile-deletion-tool
	#>
	If (Test-Path -Path '.\DelProf2.exe' -PathType Leaf) { $DelProfCmd = '.\DelProf2.exe' }
	If (Test-Path -Path '.\Tools\DelProf2.exe' -PathType Leaf) { $DelProfCmd = '.\Tools\DelProf2.exe' }
	If ($DelProfCmd) {
		$Argument = 'u' #'l'
		$PrimaryUser = (Get-WmiObject -Namespace 'root\CIMv2\SMS' -Class SMS_SystemConsoleUser).SystemConsoleUser
		Start-Process -FilePath "$DelProfCmd" -ArgumentList "/ed:$PrimaryUser /d:$ProfileAgeInDays /$argument" -Wait -Verb RunAs
	} Else {
		Write-LogMessage -Message 'DelProf2.exe not found'
	}
}
If (Test-ShouldContinue) { #Cleanup WinSXS folder... requires reboot to finalize
	Write-LogMessage -Message "Cleaning up Windows WinSXS folder"
    If ([Environment]::OSVersion.Version -lt (New-Object 'Version' 6,2)) {
		Write-LogMessage -Message "Cleaning up Windows WinSXS folder using DISM online /Cleanup-Image /SpSuperseded"
		Start-Process -FilePath "$env:SystemRoot\System32\DISM.exe" -ArgumentList '/online /Cleanup-Image /SpSuperseded' -Verb RunAs -Wait -ErrorAction SilentlyContinue -PassThru
    } Else {
		Write-LogMessage -Message "Cleaning up Windows WinSXS folder using DISM /online /Cleanup-Image /StartComponentCleanup /ResetBase"
		Start-Process -FilePath "$env:SystemRoot\System32\DISM.exe" -ArgumentList '/online /Cleanup-Image /StartComponentCleanup /ResetBase' -Verb RunAs -Wait -ErrorAction SilentlyContinue -PassThru
    }
}
If (Test-ShouldContinue) { #Run Disk Cleanup Manager with default safe settings
	Start-CleanManager -WaitSeconds 600
}
If (Test-ShouldContinue) { #Purge Delivery Optimization Files
	try {
		[int]$CacheBytes = (Get-DeliveryOptimizationStatus -ErrorAction Stop).FileSizeInCache
		Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
		Write-LogMessage -Message "Purged [$([math]::Round($CacheBytes/1mb,1)) MB] from Delivery Optimization cache"
		[int]$CacheBytes = (Get-DeliveryOptimizationStatus -ErrorAction Stop).FileSizeInCache
	} catch {
		Write-LogMessage -Message "Unable to purge from Delivery Optimization cache with PowerShell.  Trying Disk Cleanup Manager"
		$CacheBytes = 1
	}
	If ($CacheBytes -gt 0) {
		Start-CleanManager -WaitSeconds 120 -VolumeCaches 'Delivery Optimization Files'
	}
}
If (Test-ShouldContinue) { #Purge BranchCache
	try {
		[int]$CacheBytes = (Get-BCDataCache -ErrorAction Stop).CurrentSizeOnDiskAsNumberOfBytes
		Clear-BCCache -Force -ErrorAction Stop
		Write-LogMessage -Message "Purged [$([math]::Round($CacheBytes/1mb,1)) MB] from BranchCache cache"
		[int]$CacheBytes = (Get-BCDataCache -ErrorAction Stop).CurrentSizeOnDiskAsNumberOfBytes
	} catch {
		Write-LogMessage -Message "Unable to purge from BranchCache cache with PowerShell.  Trying Disk Cleanup Manager"
		$CacheBytes = 1
	}
	If ($CacheBytes -gt 0) {
		Start-CleanManager -WaitSeconds 120 -VolumeCaches 'BranchCache'
	}
}
If (Test-ShouldContinue) { #Run Disk Cleanup Manager to purge Content Indexer Cleaner
	Start-CleanManager -WaitSeconds 120 -VolumeCaches 'Content Indexer Cleaner'
}
If (Test-ShouldContinue) { #Run Disk Cleanup Manager to purge Device Driver Packages
	Start-CleanManager -WaitSeconds 120 -VolumeCaches 'Device Driver Packages'
}
If (Test-ShouldContinue) { #Run Disk Cleanup Manager to purge Windows Error Reporting files
	Start-CleanManager -WaitSeconds 120 -VolumeCaches 'Windows Error Reporting Archive Files', 'Windows Error Reporting Files', 'Windows Error Reporting Queue Files', 'Windows Error Reporting System Archive Files', 'Windows Error Reporting System Queue Files', 'Windows Error Reporting Temp Files'
}
If (Test-ShouldContinue) { #Purge System Restore Points
	Write-LogMessage -Message 'Starting System Restore Point Cleanup'
	Start-Process -FilePath "$env:SystemRoot\System32\VSSadmin.exe" -ArgumentList 'Delete Shadows', "/For=$env:SystemDrive",'/Oldest /Quiet' -Verb RunAs -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue -PassThru
}
#TODO: Mark OneDrive files as cloud-only (on-demand)
If (Test-ShouldContinue) { #purge Old items in Recycle Bin !!! BE CAREFUL !!!
	#Clear entire Recycle Bin with Disk Cleanup Manager: Start-CleanManager -Wait -VolumeCaches 'Recycle Bin'
	#Clear entire Recycle Bin with PowerShell v5: Clear-RecycleBin -DriveLetter "$env:SystemRoot\" -Force -Verbose
	#ENHANCEMENT: Delete Recycle Bin items deleted more than x days ago
	$Recycler = (New-Object -ComObject Shell.Application).NameSpace(0xa)
	$Recycler.items() | ForEach-Object {
		Remove-File -FilePath $_.path -CreatedMoreThanDaysAgo 8
		#Remove-Item -Include $_.path -Force -Recurse
	}
}
If ($script:HibernationEnabled -eq $true) {
	Enable-WindowsHibernation
}
#endregion ######################### Main Script ###############################
#region    ######################### Deallocation ##############################
$EndFreeMB = Get-FreeMB
Write-LogMessage -Message "$('{0:n0}' -f $($EndFreeMB - $StartFreeMB)) MB of space were cleaned up"
Write-LogMessage -Message "$('{0:n0}' -f $EndFreeMB) MB of free disk space exists after cleanup"
If ((Get-FreeMB) -lt $MinimumFreeMB) {
	$ReturnCode = 112 #/ 0x00000070 / ERROR_DISK_FULL / There is not enough space on the disk.  This is a ConfigMgr FailRetry error number
	Write-LogMessage -Message "WARNING: the minimum amount of free disk space of $('{0:n0}' -f $MinimumFreeMB) MB could not be achieved." -Type Warning
} Else { $ReturnCode = 0 }
Stop-Script -ReturnCode $ReturnCode
#endregion ######################### Deallocation ##############################