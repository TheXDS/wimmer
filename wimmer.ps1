[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param
(
    [Parameter(ParameterSetName = 'Automagic', Mandatory = $true, Position = 0)]
    [Switch] $Automagic,
    [Parameter(ParameterSetName = 'Automagic', Mandatory = $true, Position = 1)]
    [System.IO.FileInfo] $WimFile = $null,
    [Parameter(ParameterSetName = 'Automagic', Mandatory = $true, Position = 2)]
    [System.Nullable[int]] $WimIndex = $null,

    [Parameter(ParameterSetName = 'Interactive')]
    [Parameter(ParameterSetName = 'Automagic', Mandatory = $true)]
    [Parameter(ParameterSetName = 'Autoby', Mandatory = $true, Position = 0)]
    [System.Nullable[int]] $TargetDisk = $null,

    [Parameter(ParameterSetName = 'Autoby', Mandatory = $true)]
    [ValidateSet('Manufacturer', 'Model', 'SerialNumber', IgnoreCase = $true)]
    [string] $AutoBy,

    [Parameter(ParameterSetName = 'Autoby', Mandatory = $true)]
    [System.IO.FileInfo] $AutoFile,

    [Parameter(ParameterSetName = 'Interactive')]
    [Parameter(ParameterSetName = 'Autoby')]
    [System.IO.DirectoryInfo] $ImagesPath = $pwd.Path,

    [Parameter(ParameterSetName = 'Automagic')]
    [Parameter(ParameterSetName = 'Autoby')]
    [ValidateSet('Shutdown', 'Reboot', IgnoreCase = $true)]
    [string] $PowerAction,

    [Parameter(ParameterSetName = 'Interactive')]
    [Parameter(ParameterSetName = 'Automagic')]
    [Parameter(ParameterSetName = 'Autoby')]    
    [ValidateSet('MBR', 'GPT', IgnoreCase = $true)]
    [string] $ForceBootMode,

    [Parameter(ParameterSetName = 'Interactive')]
    [Parameter(ParameterSetName = 'Automagic', Mandatory = $true)]
    [Parameter(ParameterSetName = 'Autoby', Mandatory = $true)]
    [Switch] $YesImAbsolutelySure,

    [Parameter(ParameterSetName = 'Interactive')]
    [Parameter(ParameterSetName = 'Automagic')]
    [Parameter(ParameterSetName = 'Autoby')]
    [Switch] $DryRun,

    [Parameter(ParameterSetName = 'Version', Mandatory = $true)]
    [Switch] $Version
)

# Inicializaciones básicas...
$ver = [System.Version]::new(3, 0, 0, 0)

Write-Host @"
`nTheXDS Wimmer
Versión $ver
Utilidad de implementación alternativa de imágenes de Windows
Copyright © 2018-2020 TheXDS! non-Corp.
bajo licencia GPLv3
"@

# La versión igual aparece en el banner. No es necesario volver a mostrarla.
if ($Version) { exit }

$ForceGPT = $ForceBootMode.ToLower() -eq 'gpt'
$ForceMBR = $ForceBootMode.ToLower() -eq 'mbr'
$Shutdown = $PowerAction.ToLower() -eq 'shutdown'
$Reboot = $PowerAction.ToLower() -eq 'reboot'

#region Sanidad de argumentos...
if ($ImagesPath -and !$ImagesPath.Exists) {
    New-Exception "System.DirectoryNotFoundException" -args "La ruta de imágenes especificada no es válida.", $ImagesPath
}
if ($WimFile -and !$WimFile.Exists){
    New-Exception "System.FileNotFoundException" -args "El archivo de imagen no existe.", $WimFile
}
if ($null -ne $TargetDisk -and $null -eq @(Get-Disk)[$TargetDisk]) {
    New-Exception "System.ArgumentOutOfRangeException" -args "TargetDisk", "El disco especificado no existe." 
}

if ($DryRun) { Write-Information "-- MODO DE SIMULACIÓN --" }
if ($YesImAbsolutelySure) { Write-Warning "Se confirmarán las operaciones peligrosas automáticamente. Espero que sepas muy bien lo que haces." }
if ($Shutdown) { Write-Information "El equipo se apagará luego de completar la instalación." }
if ($Reboot) { Write-Information "El equipo se reiniciará luego de completar la instalación." }
if ($ForceBootMode) { Write-Information "Forzar instalación en modo $($ForceBootMode.ToUpper())" }


#endregion

# Funciones
function Start-Install {
    $parts = Initialize-Target $TargetDisk
    if ($null -eq $parts) { return }
    if ($DryRun){
        if ($null -eq (Install-Windows -SystemDisk $parts.RootPartition -WimFile $WimFile -WimIndex $WimIndex)) { return }
        if ($null -eq (Install-Bootloader -WindowsDisk $parts.RootPartition -BootDisk $parts.BootPartition)) { return }
        if ($Reboot) { Write-Host "-- SIMULACIÓN -- Reiniciar el equipo" ; return }
        if ($Shutdown) { Write-Host "-- SIMULACIÓN -- Apagar el equipo" ; return }
    } else {
        if ($null -eq (Install-Windows -SystemDisk $parts.RootPartition.DriveLetter -WimFile $WimFile -WimIndex $WimIndex)) { return }
        if ($null -eq (Install-Bootloader -WindowsDisk $parts.RootPartition.DriveLetter -BootDisk $parts.BootPartition.DriveLetter)) { return }
        if ($Reboot) { Restart-Computer -ComputerName localhost ; return }
        if ($Shutdown) { Stop-Computer -ComputerName localhost ; return }
    }
}

function Initialize-Target([System.Nullable[System.Int32]]$DiskId = $null, [Switch]$WithRecovery) {
    $disks = @(Get-PhysicalDisk | Sort-Object -Property DeviceId)
    if ($disks.Count.Equals(0)) {
        Write-FailMsg "No hay unidades de almacenamiento sobre las cuales instalar." -Phase 1                    
        return $null
    }

    # Comprobar y obtener unidad de destino
    if ($null -eq $DiskId) {
        $DiskId = (Select-Item -Prompt "Seleccione una unidad de destino" -FormatDelegate { param($disk) Get-DiskDescription $disk } -CheckDelegate { param($disk) return Test-DiskAvailable -disks:$disks -diskId:$disk } -Cancellable -Confirm -BaseZero -Collection $disks)
        if ($null -eq $DiskId) { return $null }
    }
    else
    {
        if (!$(Test-DiskAvailable -disks:$disks -diskId:$DiskId)){
            Write-FailMsg "La unidad especificada no está disponible para instalar." -Phase 1                    
            return $null
        }
    }

    #Particionar
    Write-Warning "TODA LA INFORMACIÓN DE LA UNIDAD $DiskId $($disks[$DiskId].FriendlyName) ($(Show-AsGBytes $disks[$DiskId].Size) GB) SERÁ DESTRUIDA."
    if (Get-Confirmation $False) {
        try {
            [hashtable]$Return = @{}
            
            $Return.Disk = Initialize-TargetDisk $DiskId
            if (!$DryRun -and $null -eq $Return.Disk) { return $null }

            $Return.BootPartition = New-BootPartition $DiskId
            if ($WithRecovery) { $Return.RecoveryPartition = New-RecoveryPartition $DiskId }            
            $Return.RootPartition = New-SystemPartition $DiskId
        
            Write-Progress "Unidad inicializada correctamente." -Completed

            Return $Return 
        } catch {
            Write-Progress "Error" -Completed
            Write-FailMsg "Ocurrió un problema al inicializar el disco." -Phase 1
            return $null
        }
    }
    else
    {
        Write-Host "Operación cancelada. No se ha realizado ningún cambio en el sistema."
        return $null
    }
}

function Install-Windows {
    param(
    [string]$SystemDisk = $null,
    [string]$WimFile = $null,
    [System.Nullable[System.Int32]] $WimIndex = $null)
    
    if ($AutoBy){
        $imgsSelector = Import-Csv -Path $AutoFile -Header 'Value', 'File', 'Index'
        switch ($AutoBy.ToLower()) {
            'manufacturer' { $val = $(Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer }
            'model' { $val = $(Get-CimInstance -ClassName Win32_ComputerSystem).Model }
            'serialnumber' { $val = $(Get-CimInstance -ClassName Win32_BIOS).SerialNumber }
        }

        foreach ($item in $imgsSelector) {
            if ($item.Value -eq $val){
                $WimFile = $item.File
                $WimIndex = $item.Index
                break
            }
        }
    }
    else {

        if ($null -eq $WimFile -or $WimFile -eq "") {
            $indx = Select-Item -Collection $list -Prompt "Seleccione una imagen de instalación" -Cancellable
            if ($null -eq $indx) { return $null }
            $WimFile = $list[$indx-1]
        }
        
        if ($null -eq $WimIndex) {
            $WimIndex = Select-Item -Collection @(Get-WindowsImage -ImagePath:$WimFile) -Prompt "Seleccione una versión a instalar" -Cancellable -FormatDelegate { param($img) Get-BasicImageIndexInfo $img }
            if ($null -eq $WimIndex) { return $null }
        }
        
        if ($null -eq $SystemDisk) {
            $vols = @(@(get-volume) | where-Object {$_.DriveType -eq "Fixed" -and (Get-Partition -Volume $_).Type -eq "Basic"})
            
            $indx = Select-Item -Collection $vols -FormatDelegate {[OutputType([string])] param($v) return "$($v.DriveLetter) '$($v.FileSystemLabel)'" } -Prompt "Seleccione una unidad de instalación" -Cancellable
            if ($null -eq $indx) { return $null }
            $SystemDisk = $vols[$indx - 1].DriveLetter
        }
    }

    $name = (Get-WindowsImage -ImagePath $([System.IO.Path]::GetFullPath($WimFile)))[$WimIndex - 1].ImageName

    if ($DryRun) { 
        Write-Host "-- SIMULACIÓN -- Instalación de $name en la unidad ${SystemDisk}:\"
        return $True
    }
    try {
        Write-Host "Instalando $name en la unidad ${SystemDisk}:\..."
        Expand-WindowsImage -ImagePath $([System.IO.Path]::GetFullPath($WimFile)) -ApplyPath ${SystemDisk}:\ -Index $WimIndex | Out-Null
        Write-Host "Se ha instalado $name en la unidad ${SystemDisk}:\"
        return $True
    }
    catch {
        Write-FailMsg "Hubo un problema al instalar Windows" -Phase 2
    }
    return $null
}

function Install-Bootloader {
    param([string]$WindowsDisk = $null, [string]$BootDisk = $null)

    if ($null -eq $WindowsDisk -or $WindowsDisk -eq "") {
        $WindowsDisk = (Select-Volume -Prompt "Seleccione la unidad en donde se encuentra instalado Windows")
        if ($null -eq $WindowsDisk -or $WindowsDisk -eq "") { return $null }
    }
    if ($null -eq $BootDisk -or $BootDisk -eq "") {
        $BootDisk = (Select-Volume -Prompt "Seleccione la unidad de arranque" -PartType "System")
        if ($null -eq $BootDisk -or $BootDisk -eq "") { return $null }
    }

    if ($DryRun) { 
        if ($(Get-BiosType) -eq 2) {
            Write-Host "-- SIMULACIÓN -- Instalación de cargador de arranque EFI en unidad ${BootDisk}:\"
        } else {
            Write-Host "-- SIMULACIÓN -- Instalación de cargador de arranque MBR en unidad ${BootDisk}:\"
        }
        return $true
    }

    bcdboot ${WindowsDisk}:\Windows -s ${BootDisk}: -f ALL
    if (!$?) {
        bcdboot ${WindowsDisk}:\Windows -s ${BootDisk}: -f BIOS
        if (!$?) {
            Write-FailMsg "Hubo un problema al instalar el cargador de arranque." -Phase 3
            return $null
        } else {
            if ($(Get-BiosType) -eq 2) {
                Write-Warning "La imagen únicamente soporta modo Legacy. Asegúrese de configurar el Firmware del equipo para arrancar en modo MBR."
            }
        }
        bootsect -nt60 ${BootDisk}: -mbr
    } else {
        if ($(Get-BiosType) -ne 2) {
            bootsect -nt60 ${BootDisk}: -mbr
            Write-Host "Sector de arranque MBR actualizado."
        }
        else {
            Write-Host "Cargador EFI instalado satisfactoriamente."
        }        
    }
    return $true
}

#region Operaciones
function Initialize-TargetDisk {
    param([System.Nullable[System.Int32]]$DiskId = 0)
    if ($(Get-BiosType) -eq 2) {
        return Initialize-PartTbl $DiskId "GPT"
    } else {
        return Initialize-PartTbl $DiskId "MBR"
    }
}

function Initialize-PartTbl {
    param ([System.Int32]$DiskId, [System.String]$PartStyle)
    if ($DryRun) { 
        Write-Host "-- SIMULACIÓN -- Creación de tabla $PartStyle en unidad $DiskId"
        return $null
    }
    [ciminstance]$disk = Get-Disk -Number $DiskId
    Write-Progress "Inicializando la unidad de disco con tabla de particiones $PartStyle..." -PercentComplete 0
    if ($disk.PartitionStyle -eq "RAW"){
        return Initialize-Disk -Number $DiskId -PartitionStyle $PartStyle -PassThru
    } else {
        Write-Warning "LA UNIDAD $((Get-DiskDescription $disk).ToUpper()) CONTIENE INFORMACIÓN. AL REFORMATEAR LA UNIDAD, TODA ESTA INFORMACIÓN SE PERDERÁ."
        if ($(Get-Confirmation -defaultVal $False -message "¿ESTÁ TOTALMENTE SEGURO QUE DESEA CONTINUAR? (s/N)") -eq $False)
        {
            Write-Host "Operación peligrosa cancelada, no se han realizado cambios al sistema."
            Write-Progress -Completed
            return $null
        }

        try {
            $Invocation = (Get-Variable MyInvocation -Scope 1).Value
            $thisRoot = $([System.IO.FileInfo]::new($Invocation.PSScriptRoot)).Directory.Root.ToString()
            foreach ($j in $disk | Get-Partition)
            {
                if ("$($j.DriveLetter):\" -eq $thisRoot) {
                    Write-Host "No se puede destruir la unidad desde la cual se ejecuta Wimmer. Alto."
                    Write-Progress -Completed
                    return $null
                }
            }
        }
        catch {
            Write-Warning "No fue posible comprobar si Wimmer se ejecuta desde una unidad de almacenamiento local."
            if ($(Get-Confirmation -defaultVal $False -message "SIENTO SER TAN INSISTENTE, PERO ¿ESTÁ TOTALMENTE SEGURO QUE DESEA CONTINUAR? DE NUEVO, LA UNIDAD ES $((Get-DiskDescription $disk).ToUpper()) (s/N)") -eq $False)
            {
                Write-Host "Operación peligrosa cancelada, no se han realizado cambios al sistema."
                Write-Progress -Completed
                return $null
            }
        }

        return Clear-Disk -Number $DiskId -RemoveData -RemoveOEM -Confirm:$False -PassThru | Initialize-Disk -PartitionStyle $PartStyle -PassThru
    }
}

function New-BootPartition {
    param([System.UInt32]$DiskId = 0, [System.UInt64]$PartitionSize = [System.UInt64]104857600)
    if ($DryRun) { 
        Write-Host "-- SIMULACIÓN -- Creación de partición EFI/Arranque de $(Show-AsMBytes $PartitionSize)"
        return "E"
    }
    if ($(Get-BiosType) -eq 2) {
        Write-Progress "Creando partición EFI..." -PercentComplete 10
        return New-Partition $DiskId -Size $PartitionSize -GptType "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" -AssignDriveLetter | Format-Volume -FileSystem FAT32 -NewFileSystemLabel "ESP"
    }
    else {
        Write-Progress "Creando partición de arranque..." -PercentComplete 10
        return New-Partition $DiskId -Size $PartitionSize -IsActive -AssignDriveLetter | Format-Volume -FileSystem NTFS -NewFileSystemLabel "Boot"
    }
}

function New-RecoveryPartition {
    param([System.UInt32]$DiskId = 0, [System.UInt64]$PartitionSize = [System.UInt64]524288000)
    if ($DryRun) { 
        Write-Host "-- SIMULACIÓN -- Creación de recuperación de $(Show-AsMBytes $PartitionSize)"
        return "R"
    }
    Write-Progress "Creando partición de recuperación..." -PercentComplete 20

    if ($(Get-BiosType) -eq 2) {
        $part = New-Partition $DiskId -Size $PartitionSize -GptType "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}" -AssignDriveLetter
    }
    else {
        $part = New-Partition $DiskId -Size $PartitionSize -IsHidden -AssignDriveLetter
    }
    return Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel "Recuperación"
}

function New-SystemPartition {
    param([System.UInt32]$DiskId = 0, [System.Nullable[System.UInt64]] $PartitionSize = $null)
    if ($DryRun) { 
        Write-Host "-- SIMULACIÓN -- Creación de partición del sistema de $(Show-AsGBytes $PartitionSize)"
        return "C"
    }
    Write-Progress "Creando partición del sistema..." -PercentComplete 30
    if ($null -eq $PartitionSize) {
        $part = New-Partition $DiskId -UseMaximumSize -AssignDriveLetter

    }
    else {
        $part = New-Partition $DiskId -Size $PartitionSize -AssignDriveLetter
    }

    return Format-Volume -Partition $part -FileSystem NTFS
}
#endregion

#region Auxiliares

function Get-IsAdmin() {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
}
function New-Exception ([string] $exType, [System.Array] $exargs) {
    try {
        $exception = New-Object -TypeName $exType -ArgumentList $exargs
        throw $exception
    }
    catch {
        throw "${exType}: $exargs"
    }
}

function Get-DiskDescription {
    [OutputType([string])] param([ciminstance] $disk)
    "$($disk.MediaType) $($disk.FriendlyName) ($(Show-AsGbytes $disk.Size) GB)"
}

function Get-Images {

    param ([System.IO.DirectoryInfo] $Path,  [System.String[]] $Extensions)
    $imgs = [System.Collections.Generic.List[System.String]]::new()
    foreach ($j in $Extensions) {
        foreach ($k in $Path.GetFiles("*.$j")) { $imgs.Add($k.FullName) }
    }
    return $imgs
}

function Write-FailMsg {
    param ([Parameter(Mandatory=$True)][System.String]$Message, [System.Int32]$Phase = 0)
    Write-Error $message
    if ($Shutdown)
    {
        for ($i = 1; $i -le 3; $i++) {
            for ($j = 1; $j -le $phase; $j++) {
                [console]::beep(1700, 300)
            }
            Start-Sleep -Seconds 1
        }
        Write-Warning "Saliendo a una consola interactiva para resolver el problema..."
    }
    exit
}

function Show-AsGBytes {
    param([Parameter(Mandatory=$True)][int64]$bytes)
    return "{0:N2} GiB" -f ($bytes / 1073741824)
}

function Show-AsMBytes {
    param([Parameter(Mandatory = $True)][int64]$bytes)
    return "{0:N2} MiB" -f ($bytes / 1048576)
}

function Show-ImageInfo {
    param([Parameter(Mandatory = $True)][string]$file)
    $count=0
    Write-Output $file
    foreach ($k in Get-WindowsImage -ImagePath:$file) {
        foreach ($l in $k){
            Write-Output "$($l.ImageIndex)) $($l.ImageName)"
            $count++
        }
    }
    Write-Output `n
}

function Show-DetailedImageInfo {
    param([Parameter(Mandatory = $True)][string]$file)
    Write-Output $file

    $count=$(Get-WindowsImage -ImagePath:$file).Count
    for ($j = 1; $j -lt $($count + 1); $j++)
    {
        Show-DetailedImageIndexInfo (Get-WindowsImage -ImagePath $file -Index $j)
    }
    Write-Output `n
}

function Show-DetailedImageIndexInfo {
    param ($Image)
    Write-Output "$($Image.ImageIndex)) $($Image.ImageName) ($(Get-ArchString $Image.Architecture)) $($Image.Version) $($Image.Languages[$Image.DefaultLanguageIndex])"
    if ($null -ne $Image.ImageDescription -and $Image.ImageDescription -ne "" -and $Image.ImageDescription -ne $Image.ImageName) {
        Write-Output "$($Image.ImageDescription)`n"
    }

}

function Get-ArchString ([int]$Value) {
    return $(switch ($Value) {
        0 { "i386" }
        9 { "AMD64" }
        Default { "???" }
    })
}

function Get-BasicImageIndexInfo($Image) {
    return "$($Image.ImageName) $($Image.Version)"
}

function Get-Confirmation {
    param(
    [System.Nullable[bool]]$defaultVal = $null,
    [string]$message = "¿Está seguro que desea continuar (s/n)?"
    )
    if ($YesImAbsolutelySure) { return $True }
    while($True) {
        switch ($(Read-Host $message).ToLower()) {
            's' { return $True }
            'n' { return $false} 
            ''{ 
                if (!$defaultVal)
                {
                    Write-Output "Debe responder Sí o No."
                }
                else
                {
                    return $defaultVal
                }
            }
            default {
                Write-Output "Opción inválida."
            }
        }
    }
}

Function Get-BiosType {
    [OutputType([UInt32])] Param()
    if ($ForceMBR) { return 1 }
    if ($ForceGPT) { return 2 }

    Add-Type -Language CSharp -TypeDefinition @'
    using System;
    using System.Runtime.InteropServices;
    public static class FirmwareType
    {
        [DllImport("kernel32.dll")]
        static extern bool GetFirmwareType(ref uint FirmwareType);
        public static uint GetFirmwareType()
        {
            uint firmwaretype = 0;
            if (GetFirmwareType(ref firmwaretype))
                return firmwaretype;
            else
                return 0;
        }
    }
'@
    [FirmwareType]::GetFirmwareType()
}

function Test-DiskAvailable {
    param($disks, $diskId)
    foreach ($d in $disks) {
        if ($d.DeviceId -eq $diskId) { return $True}
    }
    return $False
}

function Select-Item {    
    [OutputType([System.Nullable[System.UInt32]])] param(
        [System.Collections.IEnumerable] $Collection,
        [System.Func[System.Object, System.String]] $FormatDelegate = { param ($Item) return $Item.ToString() },
        [System.Func[System.Int32, System.Boolean]] $CheckDelegate = { param ($Index) return $True },
        [System.String] $Prompt = "Seleccione una opción",
        [Switch]$BaseZero,
        [Switch]$Cancellable,
        [Switch]$Confirm)
    $currentIndex = 1
    if ($BaseZero) { $currentIndex = 0 }
    $firstIndex = $currentIndex
    foreach ($item in $Collection) {        
        Write-Host "$currentIndex) $($FormatDelegate.Invoke($item))"        
        $currentIndex++
    }
    $currentIndex--
    do {
        if ($Cancellable) {
            $selection = (Read-Host "$Prompt ($firstIndex - $CurrentIndex, [Intro]=cancelar)")
            if ($null -eq $selection -or $selection -eq "") { 
                return $null
            }
        }
        else {
            $selection = (Read-Host "$Prompt ($firstIndex - $CurrentIndex)")
            if ($null -eq $selection -or $selection -eq "") { 
                $selection = -1
            }
        }
    } while (!$CheckDelegate.Invoke($selection))
    return $selection
}

function Select-Volume {
    param (
        [System.String] $Prompt = "Seleccione una unidad para continuar",
        [System.String] $DriveType = "Fixed",
        [System.String] $PartType = "Basic")

    $vols = get-volume | where-Object { $_.DriveType -eq $DriveType -and (Get-Partition -Volume $_).Type -eq $PartType }
    $indx = Select-Item -Collection $vols -FormatDelegate {[OutputType([string])] param($v) return "$($v.DriveLetter) '$($v.FileSystemLabel)'" } -Prompt $Prompt -Cancellable
    if ($null -eq $indx) { return $null }
    return $vols[$indx - 1].DriveLetter
}
#endregion

#region Menús
function show-MainMenu {
    while($True){
        switch ((Read-Host @"
`nMenú principal
==============
l) Listar las imágenes de Windows disponibles
d) Información detallada de una imagen
i) Instalar una imagen de Windows
q) Salir de esta utilidad
r) Reiniciar equipo
s) Apagar equipo
Seleccione una opción
"@).ToLower()) {
            'l' {
                Write-Host `n
                foreach ($j in $list) { $j }
            }
            'd' { Show-DetailedImageInfo -file $($list[(Select-Item -Collection $list) - 1]) }
            'i' { Show-InstallMenu }            
            'q' { exit }
            'r' { Restart-Computer ; exit }
            's' { Stop-Computer ; exit }
            default {
                Write-Host "Opción inválida." -ForegroundColor Red
            }
        }
    }
}

function Show-InstallMenu {
        while($True){
        switch ((Read-Host @"
`nInstalar una imagen de Windows
================================
a) Iniciar asistente de instalación
p) Preparar unidad de disco e instalar
w) Instalar Windows
b) Instalar el cargador de arranque de Windows en el equipo
q) Salir al menú principal
Seleccione una opción
"@).ToLower()) {
            'a' { Start-Install }
            'p' { Initialize-Target }
            'w'{ Install-Windows }
            'b'{ Install-Bootloader }
            'q'{ return } 
            default {
                Write-Host "Opción inválida." -ForegroundColor Red
            }
        }
    }
}
#endregion

# Bloque interactivo
if (!(Get-IsAdmin))
{
    Write-Error "Este script debe ejecutarse con permisos administrativos."
    exit
}

if ($null -eq $WimFile -or $WimFile -eq ""){

    $list = [System.Collections.Generic.List[System.String]](Get-Images -Path $ImagesPath -Extensions "esd", "wim", "swm")    
    if ($list.Count.Equals(0)) {
        Write-FailMsg "No hay imágenes de instalación disponibles en la ruta $ImagesPath." -Phase 4
        exit
    }    
    Write-Information "Se han detectado $($list.Count) imágenes de instalación en la ruta $ImagesPath.`n"
}
if ($Automagic) {
    Write-Information "Iniciando instalación guiada..."
    Start-Install
} else { 
    Show-MainMenu
}
return $null
