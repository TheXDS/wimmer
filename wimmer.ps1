param
(
    [System.IO.DirectoryInfo]$ImagesPath = $($pwd).Path,
    [System.Nullable[System.Int32]]$TargetDisk = $null,


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

$list = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Concat($ImagesPath.GetFiles("*.esd"), $ImagesPath.GetFiles("*.wim")))



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
        $dmax = -1
        foreach ($disk in $disks) {
            Write-Output "$($disk.DeviceId): $($disk.MediaType) $($disk.FriendlyName) ($(Show-AsGbytes $disk.Size) GB)"
            $dmax++
        }        
        do
        {
            $DiskId = Read-Host "Seleccione una unidad de destino (0-$($dmax) [Intro]=cancelar)"
            if ($DiskId -eq "") { 
                return
            }

        } while (!$(Check-DiskAvailable -disks:$disks -diskId:$DiskId))
    }
    else
    {
        if (!$(Check-DiskAvailable -disks:$disks -diskId:$DiskId)){
            Write-FailMsg "La unidad especificada no está disponible para instalar." -Phase 1                    
            return
        }
    }

    #Particionar
    Write-Warning "TODA LA INFORMACIÓN DE LA UNIDAD $DiskId $($disks[$DiskId].FriendlyName) ($(Show-AsGbytes $disks[$DiskId].Size) GB) SERÁ DESTRUIDA."
    if ($(Get-Confirmation $False) -and $(Get-Confirmation $False)) {
        try {
            Write-Progress "Inicializando la unidad de disco..." -PercentComplete 0
            $d = Clear-Disk -Number $disks[$DiskId].DeviceId -RemoveData -RemoveOEM -Confirm:$False -PassThru | Initialize-Disk -PartitionStyle GPT -PassThru
        
            $boot = Create-BootPartition
        
            if ($WithRecovery)
            {                
                $recovery = Create-RecoveryPartition
            }

            # System disk
            Write-Progress "Creando partición del sistema..." -PercentComplete 30
            $root = New-Partition $d.Number -UseMaximumSize -AssignDriveLetter | Format-Volume -FileSystem NTFS
        
            Write-Progress "Unidad inicializada correctamente." -Completed

            if (Get-BiosType -eq 2) {
                Install-Windows -disk $root.DriveLetter -bootDsk $boot.DriveLetter    
            }
            else {
                Install-Windows -disk $root.DriveLetter -bootDsk $recovery.DriveLetter    
            }


        }
        catch{
            Write-Progress "Error" -Completed
            Write-Error "Ocurrió un problema al inicializar el disco."
        }

    }
    else
    {
        Write-Host "Operación cancelada. No se ha realizado ningún cambio en el sistema."
    }
}

function Install-Windows {
    param(
    [string]$disk = $null,
    [string]$bootDsk = $null,
    [int]$wimIndex=0)
    
    $dmax=0
    foreach ($wim in $list){  
        $dmax++      
        Write-Host "$dmax) $($wim)" -ForegroundColor Magenta
    }
    while ($wimIndex -lt 1 -or $wimIndex -gt $dmax){
        $wimIndex=Read-Host "Seleccione una imagen de instalación (1-$dmax, [Intro]=Cancelar)"
        if ($wimIndex -eq $null) { return }
    }
    $dmax = show-ImageInfo $list[$wimIndex-1]
    $imgIndex = 0
    while ($imgIndex -lt 1 -or $imgIndex -gt $dmax){
        $imgIndex=Read-Host "Seleccione una versión a instalar (1-$dmax, [Intro]=Cancelar)"
        if ($imgIndex -eq $null) { return }
    }

    if (!$disk){
        $vols = get-volume | where-Object {$_.DriveType -eq "Fixed" -and (Get-Partition -Volume $_).Type -eq "Basic"}
        foreach ($v in $vols) {
            Write-Host "$v.DriveLetter) '$v.FileSystemLabel'"
        }
        while (($vols | Where-Object DriveLetter -EQ $disk).Count -eq 0){
            $disk=Read-Host "Seleccione una unidad de instalación ([Intro]=Cancelar)"
            if ($disk -eq $null) { return }
        }
    }
    $name = (Get-WindowsImage -ImagePath:$list[$wimIndex-1])[$imgIndex-1].ImageName
    Write-Host "Instalando $name en la unidad $($disk):\..."
    Expand-WindowsImage -ImagePath $list[$wimIndex-1].FullName -ApplyPath "$($disk):\" -Index $imgIndex | Out-Null
    Write-Host "Se ha instalado $name en la unidad $($disk):\"
    Install-Bootloader -winDisk $disk -bootDisk $bootDsk
}

function Install-Bootloader {
    param([string]$winDisk = $null, [string]$bootDisk=$null)

    if (!$winDisk){
        $vols = get-volume | where-Object {$_.DriveType -eq "Fixed" -and (Get-Partition -Volume $_).Type -eq "Basic"}
        foreach ($v in $vols) {
            Write-Host "$($v.DriveLetter) '$($v.FileSystemLabel)'"
        }
        while (($vols | Where-Object DriveLetter -EQ $winDisk).Count -eq 0){
            $winDisk=Read-Host "Seleccione la unidad en donde se encuentra instalado Windows ([Intro]=Cancelar)"
            if ($winDisk -eq $null) { return }
        }
    }
    if (!$bootDisk){
        $vols = get-volume | where-Object {$_.DriveType -eq "Fixed" -and (Get-Partition -Volume $_).Type -eq "Recovery"}
        foreach ($v in $vols) {
            Write-Host "$($v.DriveLetter) '$($v.FileSystemLabel)'"
        }
        while (($vols | Where-Object DriveLetter -EQ $bootDisk).Count -eq 0){
            $bootDisk=Read-Host "Seleccione la unidad de arranque ([Intro]=Cancelar)"
            if ($bootDisk -eq $null) { return }
        }        
    }

    Invoke-Expression "bcdboot $($winDisk):\Windows -s $($bootDisk): -f UEFI"
    if ($? -ne 0){
        Invoke-Expression "bcdboot $($winDisk):\Windows -s $($bootDisk): -f BIOS"
        Invoke-Expression "bootsect -nt60 "$($bootDisk):" -mbr"
        if (Get-BiosType -eq 2) {
            Write-Warning "El equipo arrancó en modo UEFI, pero la imagen únicamente soporta modo Legacy. Asegúrese de configurar el Firmware del equipo."
        }
    }
}

# Auxiliares
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

function Show-AsGbytes {
    param([Parameter(Mandatory=$true)][int64]$bytes)
    return "{0:N2}" -f ($bytes / 1073741824)
}

function show-ImageInfo {
    param([Parameter(Mandatory=$true)][string]$file)
    $count=0
    Write-Host $file -ForegroundColor Magenta
    foreach ($k in Get-WindowsImage -ImagePath:$file){
        foreach ($l in $k){
            Write-Host "$($l.ImageIndex)) $($l.ImageName)"
            $count++
        }
    }
    Write-Host `n
    return $count
}

function show-DetailedImageInfo {
    param([Parameter(Mandatory=$true)][string]$file)
    Write-Host $file -ForegroundColor Magenta
    $count=$(Get-WindowsImage -ImagePath:$file).Count
    for ($j=1; $j -lt $($count + 1); $j++)
    {
        $l = Get-WindowsImage -ImagePath $file -Index $j
        Write-Output $l
    }
    
    Write-Host `n
    return $count
}

function Get-Confirmation {
    param(
    [System.Nullable[bool]]$defaultVal = $null,
    [string]$message = "¿Está seguro que desea continuar (s/n)?"
    )
    if ($YesImAbsolutelySure) { return $true }
    while($true) {
        switch (Read-Host $message) {
            's' { return $true }
            'n' { return $false} 
            ''{ 
                if (!$defaultVal)
                {
                    Write-Host "Debe responder Sí o No." -ForegroundColor Red
                }
                else
                {
                    return $defaultVal
                }
            }
            default {
                Write-Host "Opción inválida." -ForegroundColor Red
            }
        }
    }
}

Function Get-BiosType {
    [OutputType([UInt32])]
    Param()

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

function Check-DiskAvailable {
    param($disks, $diskId)
    foreach ($d in $disks) {
        if ($d.DeviceId -eq $diskId) { return $False}
    }
    return $True
}

function Create-BootPartition {
    param([System.UInt32]$DiskId, [System.UInt64]$PartitionSize = [System.UInt64]104857600)
    if (Get-BiosType -eq 2) {
        Write-Progress "Creando partición EFI..." -PercentComplete 10
        return New-Partition $DiskId -Size $PartitionSize -GptType "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" -AssignDriveLetter | Format-Volume -FileSystem FAT32 -NewFileSystemLabel "ESP"
    }
    else {
        Write-Progress "Creando partición de arranque..." -PercentComplete 10
        return New-Partition $DiskId -Size $PartitionSize -IsActive -IsHidden -AssignDriveLetter | Format-Volume -FileSystem NTFS -NewFileSystemLabel "Boot"
    }
}

function Create-RecoveryPartition {
    param([System.UInt32]$DiskId, [System.UInt64]$PartitionSize = [System.UInt64]524288000)
    Write-Progress "Creando partición de recuperación..." -PercentComplete 20

    if (Get-BiosType -eq 2) {
        $part = New-Partition $DiskId -Size $PartitionSize -GptType "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}" -AssignDriveLetter
    }
    else {
        Write-Progress "Creando partición de arranque..." -PercentComplete 10
        $part = New-Partition $DiskId -Size $PartitionSize -IsHidden -AssignDriveLetter
    }
    return Format-Volume -CimSession $part -FileSystem NTFS -NewFileSystemLabel "Recuperación"
}

function Select-Item {
    param(
        [System.Collections.IEnumerable] $Collection,
        [System.Func[System.Object, System.String]] $FormatDelegate = { param ($Item) return $Item.ToString() },
        [System.Func[System.Int32,System.Boolean]] $CheckDelegate = { param ($Index) return $true },
        [System.String] $Prompt = "Seleccione una opción",
        [Switch]$BaseZero,
        [Switch]$Cancellable,
        [Switch]$Confirm)
    $currentIndex = 1
    if ($BaseZero) { $currentIndex = 0 }
    $firstIndex = 1
    foreach ($item in $Collection) {
            Write-Output "$currentIndex): $($FormatDelegate.Invoke($item))"
            $currentIndex++
        }
    do
    {
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
    } while (    !$CheckDelegate.Invoke($selection))
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
        switch (Read-Host @"
`nInstalar una imagen de Windows
==============
p) Preparar unidad de disco e instalar
w) Instalar Windows
b) Instalar el cargador de arranque de Windows en el equipo
q) Salir al menú principal
Seleccione una opción
"@) {
            'p' {                
                Prepare-Target
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
    Write-Output @"
No hay imágenes de instalación disponibles en la ruta actual.
Ejecute este script desde un directorio con imágenes de instalación de Windows.
"@
    exit
}

Write-Host "Se han detectado $($list.Count) imágenes de instalación en la ruta actual.`n"

show-MainMenu