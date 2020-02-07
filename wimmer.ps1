param(
    [System.IO.DirectoryInfo]$ImagesPath=$($pwd).Path,
    [Switch]$Scripted
)

# Inicializaciones básicas...
Write-Host @"
`nTheXDS Wimmer
Utilidad de implementación alternativa de imágenes de Windows
Copyright © 2018-2020 TheXDS! non-Corp.
bajo licencia GPLv3
"@

 if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
{
    Write-Host "Este cmdlet debe ejecutarse con permisos administrativos. Alto." -ForegroundColor Red
    exit
}

$list = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Concat($ImagesPath.GetFiles("*.esd"), $ImagesPath.GetFiles("*.wim")))


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

# Funciones
function Prepare-Target {
    param([System.Nullable[System.Int32]]$dest = $null)
    if (!$dest) {
        $disks = Get-PhysicalDisk | Sort-Object -Property DeviceId
        if ($disks.Count.Equals(0)){
            Write-Host "No hay unidades de disco disponibles para instalar." -ForegroundColor Red
            return
        }
        $dmax=-1
        foreach ($disk in $disks){
            Write-Host "$($disk.DeviceId): $($disk.MediaType) $($disk.FriendlyName) ($(Show-AsGbytes $disk.Size) GB)" -ForegroundColor Green
            $dmax++
        }
        $dest=-1
        while (Check-DiskAvailable -disks:$disks -diskId:$dest){
            $dest=""
            $dest=Read-Host "Seleccione una unidad de destino (0-$($dmax) [Intro]=cancelar)"
            if ($dest -eq "") { 
                return
            }
        }
    }
    Write-Warning "TODA LA INFORMACIÓN DE LA UNIDAD $dest $($disks[$dest].FriendlyName) ($(Show-AsGbytes $disks[$dest].Size) GB) SERÁ DESTRUIDA.`nÚNICAMENTE DEBE CONTINUAR SI ESTÁ ABSOLUTAMENTE SEGURO DE QUE DESEA INSTALAR WINDOWS EN ESTA UNIDAD DE DISCO.`nDE NUEVO, LA UNIDAD SELECCIONADA ES $($disks[$dest].FriendlyName)"
    if ($(Get-Confirmation $False) -and $(Get-Confirmation $False)){

        try{
            Write-Progress "Inicializando la unidad de disco..." -PercentComplete 0
            $d = Clear-Disk -Number $disks[$dest].DeviceId -RemoveData -RemoveOEM -Confirm:$False -PassThru | Initialize-Disk -PartitionStyle GPT -PassThru
        
            # EFI System Partition
            Write-Progress "Creando partición EFI..." -PercentComplete 10
            $esp = New-Partition $d.Number -Size 104857600 -GptType "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" -AssignDriveLetter | Format-Volume -FileSystem FAT32 -NewFileSystemLabel "ESP"
        
            # Recovery
            Write-Progress "Creando partición de recuperación..." -PercentComplete 20
            $recovery = New-Partition $d.Number -Size 524288000 -GptType "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}" -AssignDriveLetter | Format-Volume -FileSystem NTFS -NewFileSystemLabel "Recuperación"
        
            # System disk
            Write-Progress "Creando partición del sistema..." -PercentComplete 30
            $root = New-Partition $d.Number -UseMaximumSize -GptType "{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}" -AssignDriveLetter | Format-Volume -FileSystem NTFS
        
            Write-Progress "Unidad inicializada correctamente." -Completed

            if (Get-BiosType -eq 2){
                Install-Windows -disk $root.DriveLetter -bootDsk $esp.DriveLetter    
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
    while($true){
        switch (Read-Host $message) {
            's' { return $true }
            'n' { return $false} 
            ''{ 
                if (!$defaultVal)
                {
                    Write-Host "Debe responder Sí o No." -ForegroundColor Red
                }
                else{
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

function Check-DiskAvailable{
    param($disks, $diskId)
    if ($diskId -eq $null) {return $False}
    foreach($d in $disks){
        if ($d.DeviceId -eq $diskId) {return $False}
    }
    return $True
}

# Bloque interactivo

if ($Scripted) {    
    return
}

if ($list.Count.Equals(0)) {
    Write-Output @"
No hay imágenes de instalación disponibles en la ruta actual.
Ejecute este script desde un directorio con imágenes de instalación de Windows.
"@
    exit
}

Write-Host "Se han detectado $($list.Count) imágenes de instalación en la ruta actual.`n"

show-MainMenu