param
(
    [System.IO.DirectoryInfo]$ImagesPath = $($pwd).Path,
    [System.Nullable[System.Int32]]$TargetDisk = $null,
    [System.String] $WimFile = $null,
    [System.Nullable[System.Int32]] $WimIndex = $null,
    [Switch]$Automagic,
    [Switch]$YesImAbsolutelySure,
    [Switch]$Shutdown,
    [Switch]$DryRun
)

# Inicializaciones básicas...
Write-Output @"
`nTheXDS Wimmer
Utilidad de implementación alternativa de imágenes de Windows
Copyright © 2018-2020 TheXDS! non-Corp.
bajo licencia GPLv3
"@

if ($DryRun) { Write-Output "-- MODO DE SIMULACIÓN --" }

if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
{
    Write-Error "Este cmdlet debe ejecutarse con permisos administrativos."
    exit
}

# Funciones
function Initialize-Target {
    param([System.Nullable[System.Int32]]$DiskId = $null, [Switch]$WithRecovery)

    $disks = @(Get-PhysicalDisk | Sort-Object -Property DeviceId)
    if ($disks.Count.Equals(0)) {
        Write-FailMsg "No hay unidades de almacenamiento sobre las cuales instalar." -Phase 1                    
        return
    }

    # Comprobar y obtener unidad de destino
    if ($null -eq $DiskId) {
        $DiskId = (Select-Item -Prompt "Seleccione una unidad de destino" -FormatDelegate { param($disk) return "$($disk.MediaType) $($disk.FriendlyName) ($(Show-AsGbytes $disk.Size) GB)"} -CheckDelegate {param($disk) return Test-DiskAvailable -disks:$disks -diskId:$DiskId} -Cancellable -Confirm -BaseZero -Collection $disks)
        if ($null -eq $DiskId) { return }
    }
    else
    {
        if (!$(Test-DiskAvailable -disks:$disks -diskId:$DiskId)){
            Write-FailMsg "La unidad especificada no está disponible para instalar." -Phase 1                    
            return
        }
    }

    #Particionar
    Write-Warning "TODA LA INFORMACIÓN DE LA UNIDAD $DiskId $($disks[$DiskId].FriendlyName) ($(Show-AsGBytes $disks[$DiskId].Size) GB) SERÁ DESTRUIDA."
    if (Get-Confirmation $False) {
        #try {
            [hashtable]$Return = @{}
            
            $Return.Disk = Initialize-TargetDisk $DiskId

            $Return.BootPartition = New-BootPartition $DiskId
            if ($WithRecovery) { $Return.RecoveryPartition = New-RecoveryPartition $DiskId }            
            $Return.RootPartition = New-SystemPartition $DiskId
        
            Write-Progress "Unidad inicializada correctamente." -Completed

            Return $Return 
        #} catch {
        #    Write-Progress "Error" -Completed
        #    Write-FailMsg "Ocurrió un problema al inicializar el disco." -Phase 1
        #    return $null
        #}
    }
    else
    {
        Write-Output "Operación cancelada. No se ha realizado ningún cambio en el sistema."
        return $null
    }
}

function Install-Windows {
    param(
    [string]$SystemDisk = $null,
    [string]$WimFile = $null,
    [System.Nullable[System.Int32]] $WimIndex = $null)
    
    if ($null -eq $WimFile -or $WimFile -eq "") {
        $indx = Select-Item -Collection $list -Prompt "Seleccione una imagen de instalación" -Cancellable
        if ($null -eq $indx) { return }
        $WimFile = $list[$indx-1]
    }

    if ($null -eq $WimIndex) {
        $WimIndex = Select-Item -Collection $(Get-WindowsImage -ImagePath:$WimFile) -Prompt "Seleccione una versión a instalar" -Cancellable -FormatDelegate {param($img) Get-BasicImageIndexInfo $img}
        if ($null -eq $WimIndex) { return }
    }

    if ($null -eq $SystemDisk) {
        $vols = get-volume | where-Object {$_.DriveType -eq "Fixed" -and (Get-Partition -Volume $_).Type -eq "Basic"}

        $indx = Select-Item -Collection $vols -FormatDelegate {[OutputType([string])] param($v) return "$($v.DriveLetter) '$($v.FileSystemLabel)'" } -Prompt "Seleccione una unidad de instalación" -Cancellable
        if ($null -eq $indx) { return }
        $SystemDisk = $vols[$indx - 1].DriveLetter
    }

    $name = (Get-WindowsImage -ImagePath $([System.IO.Path]::GetFullPath($WimFile)))[$WimIndex - 1].ImageName

    if ($DryRun) { 
        Write-Host "-- SIMULACIÓN -- Instalación de $name en la unidad ${SystemDisk}:\"
        return
    }
    try {
        Write-Host "Instalando $name en la unidad ${SystemDisk}:\..."
        Expand-WindowsImage -ImagePath $([System.IO.Path]::GetFullPath($WimFile)) -ApplyPath ${SystemDisk}:\ -Index $WimIndex | Out-Null
        Write-Host "Se ha instalado $name en la unidad ${SystemDisk}:\"
    }
    catch {
        Write-FailMsg "Hubo un problema al instalar Windows" -Phase 2
    }
}

function Install-Bootloader {
    param([string]$WindowsDisk = $null, [string]$BootDisk = $null)

    if ($null -eq $WindowsDisk) {
        $WindowsDisk = (Select-Volume -Prompt "Seleccione la unidad en donde se encuentra instalado Windows")
        if ($null -eq $WindowsDisk) { return }
    }
    if ($null -eq $BootDisk) {
        $BootDisk = (Select-Volume -Prompt "Seleccione la unidad de arranque" -PartType "System")
        if ($null -eq $BootDisk) { return }
    }

    if ($DryRun) { 
        if (Get-BiosType -eq 2) {
            Write-Host "-- SIMULACIÓN -- Instalación de cargador de arranque EFI en unidad ${BootDisk}:"
        } else {
            Write-Host "-- SIMULACIÓN -- Instalación de cargador de arranque MBR en unidad ${BootDisk}:"
        }
        return
    }

    Invoke-Expression "bcdboot ${WindowsDisk}:\Windows -s ${BootDisk}: -f ALL"
    if ($? -ne 0){
        Invoke-Expression "bcdboot ${WindowsDisk}:\Windows -s ${BootDisk}: -f BIOS"
        if ($? -ne 0){
            Write-FailMsg "Hubo un problema al instalar el cargador de arranque."
        } else {
            if (Get-BiosType -eq 2) {
                Write-Warning "La imagen únicamente soporta modo Legacy. Asegúrese de configurar el Firmware del equipo para arrancar en modo MBR."
            }
        }
        Invoke-Expression "bootsect -nt60 ${BootDisk}: -mbr"
    } else {
        if (Get-BiosType -ne 2) {
            Invoke-Expression "bootsect -nt60 ${BootDisk}: -mbr"
        }
    }
}

# Operaciones
function Start-Install {
    $parts = Initialize-Target $TargetDisk
    if ($DryRun){
        Install-Windows -SystemDisk $parts.RootPartition -WimFile $WimFile -WimIndex $WimIndex
        Install-Bootloader -WindowsDisk $parts.RootPartition -BootDisk $parts.BootPartition
        if ($Shutdown) { Write-Host "-- SIMULACIÓN -- Apagar el equipo" }
    } else {
        Install-Windows -SystemDisk $parts.RootPartition.DriveLetter -WimFile $WimFile -WimIndex $WimIndex
        Install-Bootloader -WindowsDisk $parts.RootPartition.DriveLetter -BootDisk $parts.BootPartition.DriveLetter
        if ($Shutdown) { Stop-Computer -ComputerName localhost }
    }
}

function Initialize-TargetDisk {
    param([System.Nullable[System.Int32]]$DiskId = 0)
    if (Get-BiosType -eq 2) {
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
    Write-Progress "Inicializando la unidad de disco con tabla de particiones $PartStyle..." -PercentComplete 0
    if (@(Get-Disk)[$DiskId].PartitionStyle -eq "RAW"){
        return Initialize-Disk -Number $DiskId -PartitionStyle $PartStyle -PassThru
    } else {
        return Clear-Disk -Number $DiskId -RemoveData -RemoveOEM -Confirm:$False -PassThru | Initialize-Disk -PartitionStyle $PartStyle -PassThru
    }
}

function New-BootPartition {
    param([System.UInt32]$DiskId = 0, [System.UInt64]$PartitionSize = [System.UInt64]104857600)
    if ($DryRun) { 
        Write-Host "-- SIMULACIÓN -- Creación de partición EFI de $(Show-AsMBytes $PartitionSize)"
        return "E"
    }
    if (Get-BiosType -eq 2) {
        Write-Progress "Creando partición EFI..." -PercentComplete 10
        return New-Partition $DiskId -Size $PartitionSize -GptType "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" -AssignDriveLetter | Format-Volume -FileSystem FAT32 -NewFileSystemLabel "ESP"
    }
    else {
        Write-Progress "Creando partición de arranque..." -PercentComplete 10
        return New-Partition $DiskId -Size $PartitionSize -IsActive -IsHidden -AssignDriveLetter | Format-Volume -FileSystem NTFS -NewFileSystemLabel "Boot"
    }
}

function New-RecoveryPartition {
    param([System.UInt32]$DiskId = 0, [System.UInt64]$PartitionSize = [System.UInt64]524288000)
    if ($DryRun) { 
        Write-Host "-- SIMULACIÓN -- Creación de recuperación de $(Show-AsMBytes $PartitionSize)"
        return "R"
    }
    Write-Progress "Creando partición de recuperación..." -PercentComplete 20

    if (Get-BiosType -eq 2) {
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

# Auxiliares
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
    param ([Microsoft.Dism.Commands.ImageInfoObject] $Image)
    Write-Output "$($Image.ImageIndex)) $($Image.ImageName) ($($Image.Architecture)) $($Image.Version) $($Image.Languages[$Image.DefaultLanguageIndex])"
    Write-Output "$($Image.ImageDescription)`n"
}
function Get-BasicImageIndexInfo {
    param ([Microsoft.Dism.Commands.BasicImageInfoObject] $Image)
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
            if ($selection -eq "") { 
                return $null
            }
        }
        else {
            $selection = (Read-Host "$Prompt ($firstIndex - $CurrentIndex)")
            if ($selection -eq "") { 
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

# Menús
function show-MainMenu {
    while($True){
        switch (Read-Host @"
`nMenú principal
==============
l) Listar las imágenes de Windows disponibles
i) Instalar una imagen de Windows
q) Salir de esta utilidad
Seleccione una opción
"@) {
            'l' {
                Write-Host `n
                foreach ($j in $list) {
                    Show-DetailedImageInfo $j
                }
            }
            'i' { Show-InstallMenu }            
            'q' { exit } 
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
            'a' {
                Start-Install
            }
            'p' {                
                Initialize-Target
            }
            'w'{
                Install-Windows
            }
            'b'{
                Install-Bootloader
            }
            'q'{ return } 
            default {
                Write-Host "Opción inválida." -ForegroundColor Red
            }
        }
    }
}

# Bloque interactivo
if ($null -eq $WimFile){

    $list = (Get-Images -Path $ImagesPath -Extensions "esd", "wim", "swm")    
    if ($list.Count.Equals(0)) {
        Write-FailMsg "No hay imágenes de instalación disponibles en la ruta $ImagesPath." -Phase 4
        exit
    }    
    Write-Information "Se han detectado $($list.Count) imágenes de instalación en la ruta $ImagesPath.`n"
}
if ($Automagic) { Start-Install } else { show-MainMenu }