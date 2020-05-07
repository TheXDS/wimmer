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

$list = Get-Images -Path $ImagesPath -Extensions "esd", "wim", "swm"

# Funciones
function Initialize-Target {
    param([System.Nullable[System.Int32]]$DiskId = $null, [Switch]$WithRecovery)

    $disks = Get-PhysicalDisk | Sort-Object -Property DeviceId
    if ($disks.Count.Equals(0)) {
        Write-FailMsg "No hay unidades de almacenamiento sobre las cuales instalar." -Phase 1                    
        return
    }

    # Comprobar y obtener unidad de destino
    if (!$DiskId) {
        $DiskId = Select-Item -Prompt "Seleccione una unidad de destino" -FormatDelegate { param($disk) return "$($disk.DeviceId): $($disk.MediaType) $($disk.FriendlyName) ($(Show-AsGbytes $disk.Size) GB)"} -CheckDelegate {param($disk) return Test-DiskAvailable -disks:$disks -diskId:$DiskId} -Cancellable -Confirm -BaseZero -Collection $disks
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
        try {
            [hashtable]$Return = @{}
            
            $Return.Disk = Initialize-TargetDisk $DiskId

            $Return.BootPartition = New-BootPartition $DiskId
            if ($WithRecovery) { $Return.RecoveryPartition = New-RecoveryPartition $DiskId }            
            $Return.RootPartition = New-SystemPartition $DiskId
        
            Write-Progress "Unidad inicializada correctamente." -Completed

            Return $Return 
        }
        catch {
            Write-Progress "Error" -Completed
            Write-FailMsg "Ocurrió un problema al inicializar el disco." -Phase 1
            return $null
        }
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
    
    if ($null -eq $WimFile) {
        $indx = Select-Item -Collection $list -Prompt "Seleccione una imagen de instalación" -Cancellable
        if ($null -eq $indx) { return }
        $WimFile = $list[$indx-1].FullName
    }

    if ($null -eq $WimIndex) {
        $WimIndex = Select-Item -Collection $(Get-WindowsImage -ImagePath:$WimFile) -Prompt "Seleccione una versión a instalar" -Cancellable
        if ($null -eq $WimIndex) { return }
    }

    if ($null -eq $SystemDisk) {
        $vols = get-volume | where-Object {$_.DriveType -eq "Fixed" -and (Get-Partition -Volume $_).Type -eq "Basic"}

        $indx = Select-Item -Collection $vols -FormatDelegate {[OutputType([string])] param($v) return "$($v.DriveLetter) '$($v.FileSystemLabel)'" } -Prompt "Seleccione una unidad de instalación" -Cancellable
        if ($null -eq $indx) { return }
        $SystemDisk = $vols[$indx - 1].DriveLetter
    }

    $name = (Get-WindowsImage -ImagePath $WimFile)[$WimIndex - 1].ImageName

    if ($DryRun) { 
        Write-Output "-- SIMULACIÓN -- Instalación de $name en la unidad ${SystemDisk}:\"
        return
    }
    try {
        Write-Output "Instalando $name en la unidad ${SystemDisk}:\..."
        Expand-WindowsImage -ImagePath $WimFile -ApplyPath ${SystemDisk}:\ -Index $WimIndex | Out-Null
        Write-Output "Se ha instalado $name en la unidad ${SystemDisk}:\"
    }
    catch {
        Write-FailMsg "Hubo un problema al instalar Windows" -Phase 2
    }
}

function Install-Bootloader {
    param([string]$WindowsDisk = $null, [string]$BootDisk = $null)

    if ($null -eq $WindowsDisk) {
        $WindowsDisk = Select-Volume -Prompt "Seleccione la unidad en donde se encuentra instalado Windows"
        if ($null -eq $WindowsDisk) { return }
    }
    if ($null -eq $BootDisk) {
        $BootDisk = Select-Volume -Prompt "Seleccione la unidad de arranque" -PartType "Recovery"
        if ($null -eq $BootDisk) { return }
    }

    if ($DryRun) { 
        if (Get-BiosType -eq 2) {
            Write-Progress "-- SIMULACIÓN -- Instalación de cargador de arranque EFI en unidad $BootDisk"            
        } else {
            Write-Progress "-- SIMULACIÓN -- Instalación de cargador de arranque MBR en unidad $BootDisk"            
        }
        return
    }

    Invoke-Expression "bcdboot ${WindowsDisk}:\Windows -s ${BootDisk}: -f ALL"
    if ($? -ne 0){
        Invoke-Expression "bcdboot ${WindowsDisk}:\Windows -s ${BootDisk}: -f BIOS"
        Invoke-Expression "bootsect -nt60 ${BootDisk}: -mbr"
        if ($? -ne 0){
            Write-FailMsg "Hubo un problema al instalar el cargador de arranque."
        } else {
            if (Get-BiosType -eq 2) {
                Write-Warning "La imagen únicamente soporta modo Legacy. Asegúrese de configurar el Firmware del equipo para arrancar en modo MBR."
            }
        }
    } else {
        if (Get-BiosType -ne 2) {
            Invoke-Expression "bootsect -nt60 ${BootDisk}: -mbr"
        }
    }
}

# Operaciones
function Start-Install {
    $parts = Initialize-Target $TargetDisk
    Install-Windows -SystemDisk $parts.RootPartition.DriveLetter -WimFile $WimFile -WimIndex $WimIndex
    Install-Bootloader -WindowsDisk $parts.RootPartition.DriveLetter -BootDisk $parts.BootPartition.DriveLetter
}

function Initialize-TargetDisk {
    param([System.Nullable[System.Int32]]$DiskId = 0)
    if (Get-BiosType -eq 2) {
        if ($DryRun) { 
            Write-Progress "-- SIMULACIÓN -- Creación de tabla GPT en unidad $DiskId"
            return $null
        }
        Write-Progress "Inicializando la unidad de disco con tabla de particiones GPT..." -PercentComplete 0
        try {
            return Clear-Disk -Number $DiskId -RemoveData -RemoveOEM -Confirm:$False -PassThru | Initialize-Disk -PartitionStyle GPT -PassThru
        }
        catch {
            return Initialize-Disk -Number $DiskId -PartitionStyle GPT -PassThru
        }
    } else {
        if ($DryRun) { 
            Write-Progress "-- SIMULACIÓN -- Creación de tabla MBR en unidad $DiskId"
            return $null
        }
        Write-Progress "Inicializando la unidad de disco con tabla de particiones MBR..." -PercentComplete 0
        try {
            return Clear-Disk -Number $DiskId -RemoveData -RemoveOEM -Confirm:$False -PassThru | Initialize-Disk -PartitionStyle MBR -PassThru
        }
        catch {
            return Initialize-Disk -Number $DiskId -PartitionStyle MBR -PassThru
        }
    }
}

function New-BootPartition {
    param([System.UInt32]$DiskId = 0, [System.UInt64]$PartitionSize = [System.UInt64]104857600)
    if ($DryRun) { 
        Write-Progress "-- SIMULACIÓN -- Creación de partición EFI de $(Show-AsMBytes $PartitionSize)"
        return $null
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
        Write-Progress "-- SIMULACIÓN -- Creación de recuperación de $(Show-AsMBytes $PartitionSize)"
        return $null
    }
    Write-Progress "Creando partición de recuperación..." -PercentComplete 20

    if (Get-BiosType -eq 2) {
        $part = New-Partition $DiskId -Size $PartitionSize -GptType "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}" -AssignDriveLetter
    }
    else {
        $part = New-Partition $DiskId -Size $PartitionSize -IsHidden -AssignDriveLetter
    }
    return Format-Volume -CimSession $part -FileSystem NTFS -NewFileSystemLabel "Recuperación"
}

function New-SystemPartition {
    param([System.UInt32]$DiskId = 0, [System.Nullable[System.UInt64]] $PartitionSize = $null)
    if ($DryRun) { 
        Write-Progress "-- SIMULACIÓN -- Creación de partición del sistema de $(Show-AsGBytes $PartitionSize)"
        return $null
    }
    Write-Progress "Creando partición del sistema..." -PercentComplete 30
    if ($null -eq $PartitionSize) {
        $part = New-Partition $DiskId -UseMaximumSize -AssignDriveLetter

    }
    else {
        $part = New-Partition $DiskId -Size $PartitionSize -AssignDriveLetter
    }

    return Format-Volume -CimSession $part -FileSystem NTFS
}

# Auxiliares
function Get-Images {
    param ([System.IO.DirectoryInfo] $Path,  [System.String[]] $Extensions)
    $imgs = [System.Collections.Generic.List[System.String]]::new()
    foreach ($j in $Extensions) {
        $imgs.AddRange($Path.GetFiles("*.$Extension"))
    }
    return $imgs
}

function Write-FailMsg {
    param ([Parameter(Mandatory=$true)][System.String]$Message, [System.Int32]$Phase = 0)
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
    param([Parameter(Mandatory=$true)][int64]$bytes)
    return "{0:N2}" -f ($bytes / 1073741824)
}

function Show-AsMBytes {
    param([Parameter(Mandatory=$true)][int64]$bytes)
    return "{0:N2}" -f ($bytes / 1048576)
}

function Show-ImageInfo {
    param([Parameter(Mandatory=$true)][string]$file)
    $count=0
    Write-Output $file
    foreach ($k in Get-WindowsImage -ImagePath:$file){
        foreach ($l in $k){
            Write-Output "$($l.ImageIndex)) $($l.ImageName)"
            $count++
        }
    }
    Write-Output `n
    return $count
}

function show-DetailedImageInfo {
    param([Parameter(Mandatory=$true)][string]$file)
    Write-Output $file
    $count=$(Get-WindowsImage -ImagePath:$file).Count
    for ($j=1; $j -lt $($count + 1); $j++)
    {
        $l = Get-WindowsImage -ImagePath $file -Index $j
        Write-Output $l
    }    
    Write-Output `n
    return $count
}

function Get-Confirmation {
    param(
    [System.Nullable[bool]]$defaultVal = $null,
    [string]$message = "¿Está seguro que desea continuar (s/n)?"
    )
    if ($YesImAbsolutelySure) { return $true }
    while($true) {
        switch ($(Read-Host $message).ToLower()) {
            's' { return $true }
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
        if ($d.DeviceId -eq $diskId) { return $False}
    }
    return $True
}

function Select-Item {
    param(
        [System.Collections.IEnumerable] $Collection,
        [System.Func[System.Object, System.String]] $FormatDelegate = { param ($Item) return $Item.ToString() },
        [System.Func[System.Int32, System.Boolean]] $CheckDelegate = { param ($Index) return $true },
        [System.String] $Prompt = "Seleccione una opción",
        [Switch]$BaseZero,
        [Switch]$Cancellable,
        [Switch]$Confirm)
    $currentIndex = 1
    if ($BaseZero) { $currentIndex = 0 }
    $firstIndex = 1
    foreach ($item in $Collection) {
        Write-Output "$currentIndex) $($FormatDelegate.Invoke($item))"
        $currentIndex++
    }
    do {
        if ($Cancellable) {
            $selection = Read-Host "$Prompt ($firstIndex-$CurrentIndex, [Intro]=cancelar)"
            if ($selection -eq "") { 
                return $null
            }
        }
        else {
            $selection = Read-Host "$Prompt ($firstIndex-$CurrentIndex)"
            if ($selection -eq "") { 
                $selection = -1
            }
        }
    } while (!$CheckDelegate.Invoke($selection))
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
    while($true){
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
                    show-DetailedImageInfo $j
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
        while($true){
        switch ((Read-Host @"
`nInstalar una imagen de Windows
==============
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

if ($list.Count.Equals(0)) {
    Write-FailMsg "No hay imágenes de instalación disponibles en la ruta $ImagesPath." -Phase 4
    exit
}

Write-Information "Se han detectado $($list.Count) imágenes de instalación en la ruta $ImagesPath.`n"
if ($Automagic) { Start-Install } else { show-MainMenu }