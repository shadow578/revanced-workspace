#Requires -Modules @{ModuleName="InvokeBuild";ModuleVersion="5.9.10"}

<#
  .SYNOPSIS
  build script for ReVanced

  .PARAMETER Configuration
  configuration profile to use for the build. 
  Must have a matching entry in the configured $BuildConfigurations 

  .PARAMETER Target
  device serial number to deploy revanced to. 
  if not specified, a patched apk is output

  .PARAMETER MergeSmali
  merge all smali files into a single directory.
  useful when comparing between different revisions.
  valid with any decompile task

  .EXAMPLE
  PS> Invoke-Build .

  .EXAMPLE
  PS> Invoke-Build Clean
#>
param(
    [string] $Configuration = "Default",
    [string] $Target = $null,
    [switch] $MergeSmali = $false
)

# load config file
. .\ReVanced.config.ps1

# replace named deployment target with serial number from config
# named targets are prefixed with a colon (:<name>)
if ($null -ne $Target -and $Target.StartsWith(":")) {
    # get name without colon
    $targetName = $Target.Substring(1)

    # read serial number from config
    $Target = $NamedTargets.$targetName
    assert ($null -ne $Target -and -not [string]::IsNullOrWhiteSpace($Target)) "named target '$targetName' was not found"
}


#region Internal
<#
.SYNOPSIS
Internal task to load build configuration
#>
task LoadBuildConfiguration {
    requires BuildConfigurations
    requires Configuration
    assert (-not [string]::IsNullOrWhiteSpace($Configuration))

    # load default configuration entry
    $script:BuildConfig = $BuildConfigurations.Default
    assert ($null -ne $BuildConfig) "configuration 'Default' was not found"

    # load specific configuration and merge into default
    if ($Configuration -ine "Default") {
        $cfg = $BuildConfigurations.$Configuration
        assert ($null -ne $cfg) "configuration '$Configuration' was not found"

        foreach ($key in $cfg.Keys) {
            $script:BuildConfig.$key = $cfg.$key
        }
    }

    Write-Build Blue "loaded '$Configuration' build configuration"
}

<#
.SYNOPSIS
Internal task to check the for the presence of JDK11. also sets JAVA_HOME
#>
task CheckJDK11 {
    requires JDK11Home
    requires -Path "$JDK11Home/bin/java.exe"
    $env:JAVA_HOME = $JDK11Home

    Write-Build Blue "using JDK11"
}

<#
.SYNOPSIS
Internal task to check the for the presence of JDK17. also sets JAVA_HOME
#>
task CheckJDK17 {
    requires JDK17Home
    requires -Path "$JDK17Home/bin/java.exe"
    $env:JAVA_HOME = $JDK17Home

    Write-Build Blue "using JDK17"
}

<#
.SYNOPSIS
Internal task to check the for the presence of android sdk
#>
task CheckAndroidSDK {
    requires SDKHome
    requires -Path $SDKHome
    $env:ANDROID_HOME = $SDKHome
}

<#
.SYNOPSIS
Internal task to check the for the presence of github package repository credentials, as configured in the config file
#>
task CheckGPRCredentials {
    requires GPRUserName
    requires GPRToken
    $env:GITHUB_ACTOR = $GPRUserName
    $env:GITHUB_TOKEN = $GPRToken
}

<#
.SYNOPSIS
Internal task to resolve all component build artifacts
#>
task ResolveComponentBuildArtifacts LoadBuildConfiguration, {
    # revanced-cli
    $script:CliPath = (Get-ChildItem -Path "$BuildRoot/revanced-cli/build/libs/" -Filter "revanced-cli-*-all.jar").FullName
    requires -Path $CliPath

    # revanced-patches
    $script:PatchesPath = (Get-ChildItem -Path "$BuildRoot/revanced-patches/build/libs/" -Filter "revanced-patches-*.jar").FullName
    requires -Path $PatchesPath

    # revanced-integrations
    assert ($null -ne $BuildConfig.UseIntegrationsDebugBuild)
    if ($BuildConfig.UseIntegrationsDebugBuild) {
        $script:IntegrationsPath = (Get-ChildItem -Path "$BuildRoot/revanced-integrations/app/build/outputs/apk/debug/" -Filter "*.apk").FullName
    }
    else {
        $script:IntegrationsPath = (Get-ChildItem -Path "$BuildRoot/revanced-integrations/app/build/outputs/apk/release/" -Filter "*.apk").FullName
    }
    requires -Path $IntegrationsPath
}
#endregion

#region Workspace Update & Init
<#
.SYNOPSIS
Initialize or Update the workspace, pulling all required component repositories
#>
task UpdateWorkspace {
    requires Vendor

    @("revanced-cli", "revanced-patches", "revanced-integrations") | ForEach-Object {
        $name = $_
        $path = [System.IO.Path]::Combine($BuildRoot, $name)
        if (Test-Path -Path $path) {
            # if already cloned, pull upstream
            Write-Build Blue "updating $name"
            Set-Location -Path $path
            exec { git pull }
        }
        else {
            # otherwise, clone the repo
            Write-Build Blue "cloning $name"
            exec { git clone "https://github.com/$Vendor/$name.git" $name }
        }
    }
}
#endregion

#region Components
<#
.SYNOPSIS
builds the 'revanced-cli' component from source
#>
task BuildPatcherCli CheckJDK11, CheckGPRCredentials, {
    # change into repo dir
    requires -Path "revanced-cli"
    Set-Location -Path "revanced-cli"

    # run gradle build
    Write-Build Blue "starting build of revanced-cli"
    requires -Path "gradlew.bat"
    exec { .\gradlew.bat build }
}

<#
.SYNOPSIS
builds the 'revanced-patches' component from source
#>
task BuildPatches CheckJDK11, CheckGPRCredentials, {
    # change into repo dir
    requires -Path "revanced-patches"
    Set-Location -Path "revanced-patches"

    # run gradle build
    Write-Build Blue "starting build of revanced-patches"
    requires -Path "gradlew.bat"
    exec { .\gradlew.bat build }
}

<#
.SYNOPSIS
builds the 'revanced-integrations' component from source
#>
task BuildIntegrations CheckJDK17, CheckAndroidSDK, {
    # change into repo dir
    requires -Path "revanced-integrations"
    Set-Location -Path "revanced-integrations"

    # run gradle build
    Write-Build Blue "starting build of revanced-integrations"
    requires -Path "gradlew.bat"
    exec { .\gradlew.bat build }
}

<#
.SYNOPSIS
builds all components from source
#>
task BuildComponents BuildPatcherCli, BuildPatches, BuildIntegrations

<#
.SYNOPSIS
deletes build artifacts of all components
#>
task CleanComponents {
    # revanced-cli
    remove "revanced-cli/.gradle/"
    remove "revanced-cli/build/"

    # revanced-patches
    remove "revanced-patches/.gradle/"
    remove "revanced-patches/build/"

    # revanced-integrations
    remove "revanced-integrations/.gradle/"
    remove "revanced-integrations/build/"
    remove "revanced-integrations/app/build/"
}
#endregion

#region ReVanced
<#
.SYNOPSIS
build and deploy revanced
#>
task BuildReVanced CheckJDK17, LoadBuildConfiguration, ResolveComponentBuildArtifacts, {
    requires BaseAPK

    # set cli debugging arguments
    $javaArgs = @()
    assert ($null -ne $BuildConfig.DebuggablePatcherCli)
    if ($BuildConfig.DebuggablePatcherCli) {
        Write-Build DarkYellow "revanced-cli will wait for debugger to attach!"
        $javaArgs += @(
            "-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=*:5005"
        )
    }
    
    # set common arguments
    $javaArgs += @(
        "-jar", $CliPath,
        "patch",
        "`"$BaseAPK`"",
        "--patch-bundle", "`"$PatchesPath`"",
        "--merge", "`"$IntegrationsPath`"",
        "--purge"
    )

    # add output path
    $javaArgs += @(
        "--out", [System.IO.Path]::Combine(
            [System.IO.Path]::GetDirectoryName($BaseAPK),
            "$([System.IO.Path]::GetFileNameWithoutExtension($BaseAPK)).patched.apk"
        )
    )

    # add deployment target
    if (-not [string]::IsNullOrWhiteSpace($Target)) {
        Write-Build Blue "deploy on $Target"
        $javaArgs += @(
            "--device-serial", $Target 
        )
    }

    # add args for root installation
    if ($Configuration.Root) {
        $javaArgs += @(
            "-e", "microg-support",
            "--mount" 
        )
    }

    # add debug enable
    assert ($null -ne $BuildConfig.IncludeDebuggingPatch)
    if ($BuildConfig.IncludeDebuggingPatch) {
        $javaArgs += @(
            "-i", "Enable Android debugging" 
        )
    }

    # add additional args
    if ($null -ne $BuildConfig.AdditionalPatcherArgs) {
        $javaArgs += $BuildConfig.AdditionalPatcherArgs
    }

    # run patcher
    #Write-Build Blue "invoking patcher with cmd java $($javaArgs -join " ")"
    exec { & "$env:JAVA_HOME/bin/java.exe" $javaArgs }
}

<#
.SYNOPSIS
delete revanced patched apk
#>
task CleanReVanced {
    remove "*.patched.apk"
}

<#
.SYNOPSIS
launch the specified activity
#>
task Launch -If (-not [string]::IsNullOrWhiteSpace($Target)) LoadBuildConfiguration, {
    assert ($null -ne $BuildConfig.DebuggablePatcherCli)
    assert ($null -ne $BuildConfig.MainActivity)
    if ($BuildConfig.DebuggableAppLaunch) {
        exec { adb -s $Target shell am start -D -S -n $BuildConfig.MainActivity -a "android.intent.action.MAIN" -c "android.intent.category.LAUNCHER" }
    }
    else {
        exec { adb -s $Target  shell am start -S -n $BuildConfig.MainActivity -a "android.intent.action.MAIN" -c "android.intent.category.LAUNCHER" }
    }
}
#endregion

#region Decompile
function Invoke-ApkToolDecode([string] $Apk) {
    requires ApkTool
    requires -Path $Apk

    # build output dir
    $output = [System.IO.Path]::Combine(
        $BuildRoot,
        "decompiled",
        [System.IO.Path]::GetFileNameWithoutExtension($Apk)
    )

    # run apktool
    $javaArgs = @(
        "-jar", "`"$ApkTool`"",
        "decode", "`"$Apk`"",
        "-o", "`"$output`"",
        "-f"
    )
    exec { & "$env:JAVA_HOME/bin/java.exe" $javaArgs }

    # write project dir path to variable for MergeSmali task
    $script:SmaliProjectRoot = $output
}

<#
.SYNOPSIS
decompile the stock apk
#>
task DecompileStock CheckJDK17, {
    requires BaseAPK
    Invoke-ApkToolDecode -Apk $BaseAPK
}, MergeSmali

<#
.SYNOPSIS
decompile the patched apk
#>
task DecompileReVanced CheckJDK17, {
    requires BaseAPK
    Invoke-ApkToolDecode -Apk "$([System.IO.Path]::Combine(
        [System.IO.Path]::GetDirectoryName($BaseAPK),
        "$([System.IO.Path]::GetFileNameWithoutExtension($BaseAPK)).patched.apk"
    ))"
}, MergeSmali

<#
.SYNOPSIS
Internal task to merge all smali classes into one directory
#>
task MergeSmali -If ($MergeSmali) {
    $ProjectRoot = $SmaliProjectRoot
    requires -Path $ProjectRoot

    $mainSmaliDir = [System.IO.Path]::Combine($ProjectRoot, "smali")
    requires -Path $mainSmaliDir

    # find all smali dirs
    $smaliDirs = @()
    for ($n = 2; ; $n++) {
        $path = [System.IO.Path]::Combine($ProjectRoot, "smali_classes$n")
        if (Test-Path -Path $path -PathType Container) {
            $smaliDirs += $path
            Write-Build Gray "found $path"
        }
        else {
            break
        }
    }

    # merge all smali directories into the main one
    $count = 0
    $smaliDirs | ForEach-Object {
        $smaliDir = $_
        Get-ChildItem -Path $smaliDir -Recurse -File | ForEach-Object {
            $relPath = $_.FullName.Substring($smaliDir.Length + 1)
            $destPath = [System.IO.Path]::Combine($mainSmaliDir, $relPath)

            # create destination if needed
            $destDir = [System.IO.Path]::GetDirectoryName($destPath)
            if (-not (Test-Path -Path $destDir)) {
                New-Item -Path $destDir -ItemType Directory | Out-Null
            }

            # move to destination
            Move-Item -Path $_.FullName -Destination $destPath -Force -ErrorAction SilentlyContinue
            $count++
        }
    }

    Write-Build Blue "finished moving $count smali files"
}

<#
.SYNOPSIS
deletes all decompile artifacts
#>
task CleanDecompiled {
    #remove "decompiled"

    # delete using UNC path as the decompiled dir
    # may contain file paths longer than 260 chars
    remove "\\?\$([System.IO.Path]::Combine(
        $BuildRoot,
        "decompiled"
    ))"
}
#endregion

<#
.SYNOPSIS
build all components and then revanced
#>
task BuildAll CleanReVanced, BuildComponents, BuildReVanced

<#
.SYNOPSIS
create a fresh build and then decompile it
#>
task BuildAndDecompile { Clear-Variable Target -Scope Script }, BuildAll, DecompileReVanced

<#
.SYNOPSIS
clean the whole workspace
#>
task Clean CleanComponents, CleanDecompiled, CleanReVanced

<#
.SYNOPSIS
default task builds all components and revanced, then launches revanced on the target device
#>
task . BuildAll, Launch