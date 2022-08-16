#Requires -Modules @{ModuleName="InvokeBuild";ModuleVersion="5.9.10"}

<#
  .SYNOPSIS
  build script for ReVanced

  .DESCRIPTION
  The Update-Month.ps1 script updates the registry with new data generated
  during the past month and generates a report.

  .PARAMETER Debug
  enable debug mode. 
  this enables the 'enable-debugging' patch, and build ReVanced using the debug build of integrations

  .PARAMETER DebugPatcher
  make the patcher wait for a debugger.
  useful for debugging patches

  .PARAMETER Root
  use build and deploy parameters for rooted devices

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
    [switch] $Debug = $false,
    [switch] $DebugPatcher = $false,
    [switch] $Root = $false,
    [string] $Target = $null,
    [switch] $MergeSmali = $false
)

#region load global config
. .\ReVanced.config.ps1
requires BaseAPK
requires MainActivity
requires Vendor
requires JDKHome
requires SDKHome
requires ApkTool
#endregion

#region Internal
<#
.SYNOPSIS
Internal task to check the for the presence of JDK
#>
task Check-JDK {
    requires -Path "$JDKHome/bin/java.exe"
    $env:JAVA_HOME = $JDKHome
}

<#
.SYNOPSIS
Internal task to check the for the presence of android sdk
#>
task Check-AndroidSDK {
    requires -Path $SDKHome
    $env:ANDROID_HOME = $SDKHome
}

<#
.SYNOPSIS
Internal task to resolve all component build artifacts
#>
task Resolve-ComponentBuildArtifacts {
    # revanced-cli
    $global:CliPath = (Get-ChildItem -Path "$BuildRoot/revanced-cli/build/libs/" -Filter "revanced-cli-*-all.jar").FullName
    requires -Path $CliPath

    # revanced-patches
    $global:PatchesPath = (Get-ChildItem -Path "$BuildRoot/revanced-patches/build/libs/" -Filter "revanced-patches-*.jar").FullName
    requires -Path $PatchesPath

    # revanced-integrations
    if ($Debug) {
        $global:IntegrationsPath = (Get-ChildItem -Path "$BuildRoot/revanced-integrations/app/build/outputs/apk/debug/" -Filter "app*.apk").FullName
    }
    else {
        $global:IntegrationsPath = (Get-ChildItem -Path "$BuildRoot/revanced-integrations/app/build/outputs/apk/release/" -Filter "app*.apk").FullName
    }
    requires -Path $IntegrationsPath
}
#endregion

#region Workspace Update & Init
<#
.SYNOPSIS
Initialize or Update the workspace, pulling all required component repositories. The vendor of the pulled components may be changed using the '-Vendor' option
#>
task Update-Workspace {
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
task Build-PatcherCli Check-JDK, {
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
task Build-Patches Check-JDK, {
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
task Build-Integrations Check-JDK, Check-AndroidSDK, {
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
task Build-Components Build-PatcherCli, Build-Patches, Build-Integrations

<#
.SYNOPSIS
deletes build artifacts of all components
#>
task Clean-Build {
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
task Build-ReVanced Check-JDK, Resolve-ComponentBuildArtifacts, {
    # set cli debugging arguments
    $javaArgs = @()
    if ($DebugPatcher) {
        Write-Build DarkYellow "revanced-cli will wait for debugger to attach!"
        $javaArgs += @(
            "-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=*:5005"
        )
    }
    
    # set common arguments
    $javaArgs += @(
        "-jar", $CliPath,
        "--apk", "`"$BaseAPK`"",
        "--bundles", "`"$PatchesPath`"",
        "--merge", "`"$IntegrationsPath`"",
        "--clean"
    )

    # add output path or deployment target
    if ([string]::IsNullOrWhiteSpace($Target)) {
        $javaArgs += @(
            "--out", [System.IO.Path]::Combine(
                [System.IO.Path]::GetDirectoryName($BaseAPK),
                "$([System.IO.Path]::GetFileNameWithoutExtension($BaseAPK)).patched.apk"
            )
        )
    }
    else {
        Write-Build Blue "deploy on $Target"
        $javaArgs += @(
            "--deploy-on", $Target 
        )
    }

    # add args for root installation
    if ($Root) {
        $javaArgs += @(
            "-e", "microg-support",
            "--mount" 
        )
    }

    # add debug enable
    if ($Debug) {
        $javaArgs += @(
            "-i", "enable-debugging" 
        )
    }

    # run patcher
    #Write-Build Blue "invoking patcher with cmd java $($javaArgs -join " ")"
    exec { & "$env:JAVA_HOME/bin/java.exe" $javaArgs }
}

<#
.SYNOPSIS
delete revanced patched apk
#>
task Clean-ReVanced {
    remove "*.patched.apk"
}

<#
.SYNOPSIS
launch the specified activity
#>
task Launch -If (-not [string]::IsNullOrWhiteSpace($Target)) {
    if ($Debug) {
        exec { adb -s $Target shell am start -D -S -n $MainActivity -a "android.intent.action.MAIN" -c "android.intent.category.LAUNCHER" }
    }
    else {
        exec { adb -s $Target  shell am start -S -n $MainActivity -a "android.intent.action.MAIN" -c "android.intent.category.LAUNCHER" }
    }
}
#endregion

#region Decompile
function Invoke-ApkToolDecode([string] $Apk, [string] $Output) {
    # get path to apk
    requires -Path $Apk

    # run apktool
    $javaArgs = @(
        "-jar", "`"$ApkTool`"",
        "decode", "`"$Apk`"",
        "-o", "`"$Output`"",
        "-f"
    )
    exec { & "$env:JAVA_HOME/bin/java.exe" $javaArgs }

    return $output
}

function Merge-SmaliDirs([string] $ProjectRoot) {
    Write-Build Blue "merging smali classes"
    $mainSmaliDir = [System.IO.Path]::Combine($ProjectRoot, "smali")
    
    requires -Path $ProjectRoot
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
decompile the stock apk
#>
task Decompile-Stock {
    # decompile
    $output = [System.IO.Path]::Combine(
        $BuildRoot,
        "decompiled",
        [System.IO.Path]::GetFileNameWithoutExtension($BaseAPK)
    )
    Invoke-ApkToolDecode -Apk $BaseAPK -Output $output

    # merge smali
    if ($MergeSmali) {
        Merge-SmaliDirs -ProjectRoot $output
    }
}

<#
.SYNOPSIS
decompile the patched apk
#>
task Decompile-ReVanced {
    # decompile
    $patchedApk = [System.IO.Path]::Combine(
        [System.IO.Path]::GetDirectoryName($BaseAPK),
        "$([System.IO.Path]::GetFileNameWithoutExtension($BaseAPK)).patched.apk"
    )
    $output = [System.IO.Path]::Combine(
        $BuildRoot,
        "decompiled",
        [System.IO.Path]::GetFileNameWithoutExtension($patchedApk)
    )
    Invoke-ApkToolDecode -Apk $patchedApk -Output $output

    # merge smali
    if ($MergeSmali) {
        Merge-SmaliDirs -ProjectRoot $output
    }
}

<#
.SYNOPSIS
deletes all decompile artifacts
#>
task Clean-Decompiled {
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
task BuildAll Clean-ReVanced, Build-Components, Build-ReVanced

<#
.SYNOPSIS
create a fresh build and then decompile it
#>
task BuildAndDecompile { Clear-Variable Target -Scope Script }, BuildAll, Decompile-ReVanced

<#
.SYNOPSIS
clean the whole workspace
#>
task Clean Clean-Build, Clean-Decompiled, Clean-ReVanced

<#
.SYNOPSIS
default task builds all components and revanced, then launches revanced on the target device
#>
task . BuildAll, Launch