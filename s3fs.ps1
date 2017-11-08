$ErrorActionPreference = 'stop'

Import-Module .\s3.psm1 -DisableNameChecking

function InferMimeType($Extension) {
    switch ($Extension) {
        '.txt' { 'text/plain'; break }
        '.bat' { 'text/plain'; break }
        '.sh' { 'text/plain'; break }
        '.java' { 'text/plain'; break }
        '.c' { 'text/plain'; break }
        '.go' { 'text/plain'; break }
        '.ps1' { 'text/plain'; break }
        '.psm1' { 'text/plain'; break }
        '.py' { 'text/plain'; break }
        '.cc' { 'text/plain'; break }
        '.pdf' { 'application/pdf'; break }
        '.json' { 'application/json'; break }
        '.html' { 'text/html'; break }
        '.htm' { 'text/html'; break }
        '.gif' { 'image/gif'; break }
        '.css' { 'text/css'; break }
        '.jpeg' { 'image/jpeg'; break }
        '.jpg' { 'image/jpeg'; break }
        '.js' { 'application/javascript'; break }
        '.webm' { 'video/webm'; break }
        '.png' { 'image/png'; break }
        '.zip' { 'application/zip'; break }
        '.csv' { 'text/csv'; break }
        '.doc' { 'application/msword'; break }
        '.docx' { 'application/msword'; break }
        '.xls' { 'application/vnd.ms-excel'; break }
        '.xlsx' { 'application/vnd.ms-excel'; break }
        '.ppt' { 'application/vnd.ms-powerpoint'; break }
        '.pptx' { 'application/vnd.ms-powerpoint'; break }

        default { 'application/octet-stream'; break }
    }
}

function Put-File([System.IO.FileSystemInfo]$File, [string]$RemotePath, [string]$Perm='private') {
    if (!$RemotePath) { throw 'RemotePath must be specified' }
    if (!$RemotePath.StartsWith('/')) { throw 'RemotePath must start with /' }
    if ($File.PSIsContainer) { "$($File.FullName) is not a file" }
    if ($RemotePath.EndsWith('/')) { $key = $RemotePath + $File.Name }
    else { $key = $RemotePath }
    
    $fs = [System.IO.File]::OpenRead($File.FullName)
    Write-Host "Copying $($File.FullName) to $key"
    Put-FromStream -Key $key -Perm $Perm -ContentType (InferMimeType -Extension $File.Extension) -Length $File.Length -Stream $fs
}

function Put-Folder([System.IO.FileSystemInfo]$Folder, [string]$RemotePath, [string]$Perm='private') {
    if (!$Folder.PSIsContainer) { throw "$($Folder.FullName) is not a folder"}
    if (!$RemotePath) { throw 'RemotePath must be specified' }
    if (!$RemotePath.StartsWith('/')) { throw 'RemotePath must start with /' }
    if ($RemotePath -ne '/') { $RemotePath = $RemotePath.TrimEnd('/') }

    Get-ChildItem $Folder -Recurse | ? { !$_.PSIsContainer } | % {
        if ($RemotePath -eq '/') {
            $key = $_.FullName.Replace($Folder.FullName, '').Replace('\', '/')
        } else {
            $key = $RemotePath  + $_.FullName.Replace($Folder.FullName, '').Replace('\', '/')
        }
        $fs = [System.IO.File]::OpenRead($_.FullName)
        Write-Host "Copying $($_.FullName) to $key"
        Put-FromStream -Key $key -Perm $Perm -ContentType (InferMimeType -Extension $_.Extension) -Length $_.Length -Stream $fs
    }
}

function Get-File([string]$RemotePath, [string]$Folder='.') {
    if (!$RemotePath) { throw 'RemotePath must be specified' }
    if (!$RemotePath.StartsWith('/')) { throw 'RemotePath must start with a /' }
    if ($RemotePath.EndsWith('/')) { throw 'RemotePath must be a file, not a folder (must not end with a /)' }
    $f = Get-Item $Folder
    if (!$f.PSIsContainer) { throw "$($f.FullName) is not a folder" }
    if (!(Head-Key $RemotePath)) { throw "$RemotePath does not exist" }
    $filename = $f.FullName + '\' + $RemotePath.Split('/')[-1].Replace('/','\')
    $fs = [System.IO.File]::OpenWrite($filename)
    Get-ToStream -Key $RemotePath -Stream $fs
}

function Get-Folder([string]$RemotePath, [string]$Folder='.') {
    if (!$RemotePath) { throw 'RemotePath must be specified' }
    if (!$RemotePath.StartsWith('/')) { throw 'RemotePath must start with a /' }
    if ($RemotePath -ne '/' -and !$RemotePath.EndsWith('/')) { throw 'RemotePath must be a folder (must end with a /)' }
    $f = Get-Item $Folder
    if (!$f.PSIsContainer) { throw "$($f.FullName) is not a folder" }
    Do {
        $l = List-Keys -prefix $RemotePath
        $l.Contents | % {
            $localBase = $f.FullName.TrimEnd('\')
            $localPath = $localBase + '\' + ($_.Key -replace "^$RemotePath").Replace('/', '\')
            $parent = Split-Path $localPath
            try { Get-Item $parent } catch {
                if ($_.Exception.Message -match 'it does not exist') {
                    [void](New-Item $parent -ItemType 'Directory')
                }
            }
            write-host ('Copying ' + $_.Key + ' to ' + $localPath)
            $fs = [System.IO.File]::OpenWrite($localPath)
            Get-ToStream -Key $_.Key -Stream $fs
        }
        if ($l.IsTruncated) { $marker = $l.NextMarker }
    } while ($l.IsTruncated) 
}
function Get-ToFile([System.IO.FileSystemInfo]$LocalFolder) {
    Begin {
        if (!$LocalFolder.PSIsContainer) { throw 'LocalFolder must be a folder' }
        $firstItem = $true
    }
    Process {
        [string]$key = $_
        if (!$key.StartsWith('/')) { $key = '/' + $key }
        if (!$key.EndsWith('/')) {
            if ($firstItem) { $base = (Split-Path $key).Replace('\', '/'); $firstItem = $false }
            $targetPath = $LocalFolder.FullName + '\' + ($key -replace "^$base").Replace('/', '\').TrimStart('\')
            Write-Host "Copying $key to $targetPath"
        }
    }
}

function Get-Dir([string]$Path, [switch]$Recurse) {
    if (!$Path) { throw 'Path must be specified' }
    if (!$Path.StartsWith('/')) { throw 'Path must start with a /' }
    if ($Path -ne '/' -and !$Path.EndsWith('/')) { $Path += '/' }
    do {
        if (!$Recurse) { $delimiter = '/' }
        $l = List-Keys -prefix $Path -delimiter $delimiter -marker $marker
        $l.Contents | % { [PSCustomObject]@{
                Name = $_.Key
                Size = $_.Size
                ETag = $_.ETag
                LastModified = $_.LastModified
                IsDir = $false
           }
        }
        $l.CommonPrefixes | % { [PSCustomObject]@{
            Name = $_
            Size = 0
            ETag = $null
            LastModified = $null
            IsDir = $true
           }
        }
        if ($l.IsTruncated) { $marker = $l.NextMarker }
    } while ($l.IsTruncated)
}

# Initialize the module
#Laptop
#Get-Bucket -EndPoint 'http://localhost:9000' -BucketName 'test' -AccessKey '4OSXWF5MAL6BUKJE9C72' -SecretKey 'bGkzkk9cqtCztyP1pDVARCskzzg6fwnqtz7m7xsU'

#PC
Get-Bucket -EndPoint 'http://localhost:9000' -BucketName 'test' -AccessKey '82Z7UVWLMN7K4TMP9RJF' -SecretKey 'b9PbWQoLVCHT1vq1LaE6twQIKUr3y0ArvckDSrr9'
# List all existing keys (files) on Object Storage
#Get-Dir / -Recurse | Format-Table

# List keys (files) in the /Desktop "folder"
#Get-Dir /Desktop | Format-Table

# List subfolders in the in the /Desktop folder
#Get-Dir /Desktop | ? { $_.IsDir } | Format-Table

# List files in /Desktop folder with .pdf extension
#Get-Dir /Desktop | ? { $_.Name.EndsWith('.pdf') } | Format-Table
