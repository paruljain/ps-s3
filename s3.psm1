function HmacSha1B64 ([string]$key, [string]$data) {
    $sha = [System.Security.Cryptography.KeyedHashAlgorithm]::Create("HMACSHA1")
    $sha.Key = [System.Text.Encoding]::UTF8.Getbytes($key)
    [Convert]::Tobase64String($sha.ComputeHash([System.Text.Encoding]::UTF8.Getbytes($data)))
}

function AmazonEscape([string]$data) {
    $goodChars = '[a-zA-Z0-9_\-~./:]'
    $escapedData = ''
    for ($i=0; $i -lt $data.length; $i++) {
        $char = $data[$i]
        if ($char -match $goodChars) {
            $escapedData += $char
        } else {
            $escapedData +=  '%' + '{0:X2}' -f [byte][char]$char
        }
    }
    $escapedData
}

function StringToSign([string]$method, [string]$uri, [hashtable]$params, [hashtable]$headers) {
    $paramsToSign = @(
	    "acl",
	    "delete",
	    "location",
	    "logging",
	    "notification",
	    "partNumber",
	    "policy",
	    "requestPayment",
	    "torrent",
	    "uploadId",
	    "uploads",
	    "versionId",
	    "versioning",
	    "versions",
	    "response-content-type",
	    "response-content-language",
	    "response-expires",
	    "response-cache-control",
	    "response-content-disposition",
	    "response-content-encoding"
	)
    $s2s = $method.ToUpper() + "`n"
    $s2s += $headers['content-md5'] + "`n"
    $s2s += $headers['content-type'] + "`n"
    $s2s += "`n"

    $headers.GetEnumerator() | ? { $_.Name -match '^x-amz-' } | sort -Property Name | 
        % { $s2s += $_.Name.ToLower() + ':' + $_.Value + "`n" }

    $paramStr = ''
    $params.GetEnumerator() | ? { $paramsToSign.Contains($_.Name) } | sort -Property Name |
        % {
            $paramStr += $_.Name
            if ($_.Value) { $paramStr += '=' + $_.Value  }
            $paramStr += '&'
        }
    
    $uri = AmazonEscape $uri
    if ($paramStr) { $uri += '?' + $paramStr.TrimEnd('&') }
    $s2s += $uri
    
    #write-host $s2s

    $s2s
}

function Run([string]$method, [string]$uri, [hashtable]$headers, [hashtable]$params, [uint64]$contentLength, [System.IO.Stream]$stream) {
    if (!$uri.StartsWith('/')) { $uri = '/' + $uri }

    if (!$headers) { $headers = @{} }
    if (!$params) { $params = @{} }

    $headers['x-amz-date'] = [DateTime]::UtcNow.ToString('r')

    $uri =  '/' + $bucket.BucketName + $uri

    $signature = HmacSha1B64 -key $bucket.SecretKey -data (StringToSign -method $method -uri $uri -params $params -headers $headers)
    $headers['Authorization'] = 'AWS ' + $bucket.AccessKey + ':' + $signature

    
    $paramStr = ''
    if ($params) { $params.GetEnumerator() | % {
            $paramStr += $_.Name
            if ($_.Value) { $paramStr += '=' + $_.Value }
            $paramStr += '&'
        }
    }
    $url = $bucket.EP + $uri
    if ($paramStr) { $url += '?' + $paramStr.TrimEnd('&') }

    write-host $url

    [System.Net.HttpWebRequest]$wr = [System.Net.WebRequest]::Create($url)
    $wr.Method = $method
    #$wr.KeepAlive = $false
    if ($headers.ContainsKey('Content-Type')) {
        $wr.ContentType = $headers['Content-Type']
        $headers.Remove('Content-Type')
    }

    #$wr.ServicePoint.Expect100Continue = $false
    #$wr.UserAgent = 'Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.2;)'

    $headers.GetEnumerator() | % { $wr.Headers.Add($_.Name, $_.Value) }

    switch ($method) {
        'get' {
            try {
                if (!$stream) { throw 'stream must be provided to write to' }
                $resp = $wr.GetResponse()
                $os = $resp.GetResponseStream()
                $os.CopyTo($stream)
                $stream.Flush()
                $os.Close()
                $resp.Close()
            } catch [Net.WebException] {
                if ($_.Exception.Response) {
                    if ($_.Exception.Response.StatusCode -eq 404) { throw 'Key not found'  }
                    $streamReader = [System.IO.StreamReader]::New($_.Exception.Response.GetResponseStream())
                    $message = $streamReader.ReadToEnd()
                    $streamReader.Close()
                    throw $message
                } else {
                    throw $_.Exception.ToString()
                }
            }
            break
        }
        { ($_ -eq 'put') -or ($_ -eq 'post') } {
            try {
                if ($contentLength -eq $null) { throw 'contentLength must be provided' }
                if (!$stream) { throw 'stream to read from must be provided' }
                $wr.ContentLength = $contentLength
                #Write-Host 'Debug: About to getrequesstream on PUT'
                $os = $wr.GetRequestStream()
                $stream.CopyTo($os)
                $os.Close()
                $resp = $wr.GetResponse()
                $resp.Close()
                #Write-Host 'Debug: Got getrequesstream on PUT'
            } catch [Net.WebException] {
                if ($_.Exception.Response) {
                    $streamReader = [System.IO.StreamReader]::New($_.Exception.Response.GetResponseStream())
                    $message = $streamReader.ReadToEnd()
                    $streamReader.Close()
                    throw $message
                } else {
                    throw $_.Exception.ToString()
                }
            }
            break
        }
        'delete' {
            try {
                [void]$wr.GetResponse().Close()
            } catch [Net.WebException] {
                if ($_.Exception.Response) {
                    $streamReader = [System.IO.StreamReader]::New($_.Exception.Response.GetResponseStream())
                    $message = $streamReader.ReadToEnd()
                    $streamReader.Close()
                    throw $message
                } else {
                    throw $_.Exception.ToString()
                }
            }
            break
        }
        'head' {
            try {
                $resp = $wr.GetResponse()
                $headers = @{}
                $resp.Headers.AllKeys | % { $headers[$_] = $resp.Headers[$_] }
                $resp.Close()
                [PSCustomObject]$headers
            } catch [Net.WebException] {
                if ($_.Exception.Response) {
                    if ($_.Exception.Response.StatusCode -eq 404) { return }
                    $streamReader = [System.IO.StreamReader]::New($_.Exception.Response.GetResponseStream())
                    $message = $streamReader.ReadToEnd()
                    $streamReader.Close()
                    throw $message
                } else {
                    throw $_.Exception.ToString()
                }
            }
        }
    }
}

$bucket = @{}

function Get-Bucket([string]$EndPoint, [string]$BucketName, [string]$AccessKey, [string]$SecretKey) {
    if ($EndPoint -notmatch '^https?://') { throw 'EndPoint must start with http:// or https://' }
    if (!$BucketName) { throw 'Bucket name must be provided' }
    if (!$AccessKey) { throw 'Access key name must be provided' }
    if (!$SecretKey) { throw 'Secret key name must be provided' }
 
    $bucket['AccessKey'] =  $AccessKey
    $bucket['SecretKey'] =  $SecretKey
    $bucket['BucketName'] =  $BucketName
    $bucket['EP'] = $EndPoint.TrimEnd('/')
}

function Get-ToStream([string]$Key, [System.IO.Stream]$Stream) {
    Run -method 'GET' -uri $Key -stream $Stream
    $stream.Close()
} 
function Get-Text([string]$Key, [hashtable]$Params = @{}) {
    # Returns value of the Key as [string] or $null if the Key does not exist
    $memStream = New-Object System.IO.MemoryStream
    Run -method 'GET' -uri $key -stream $memStream -params $Params
    [void]$memStream.Seek(0, 'Begin')
    $sr = [System.IO.StreamReader]::New($memStream)
    $sr.ReadToEnd()
    $sr.Close()
    $memStream.Close()
}
function Put-FromStream([string]$Key, [string]$Perm='private', [string]$ContentType='application/octet-stream', [System.IO.Stream]$Stream, [uint64]$Length) {
    if (!$Key) { throw 'Key must be specified' }
    if ($Length -eq $null) { throw 'Length of the stream (total bytes) must be specified' }
    if ($Perm -ne 'private' -and $Perm -ne 'public-read' -and $Perm -ne 'public-read-write') {
        throw 'Perm must be one of private or public-read or public-read-write'
    }

    $headers = @{
        'x-amz-acl' = $perm
        'Content-Type' = $ContentType
    }

    Run -method 'PUT' -uri $Key -headers $headers -contentLength $Length -stream $Stream
    $Stream.Close()
}

function Put-Text([string]$Key, [string]$Value, [string]$Perm='private', [string]$ContentType='text/plain') {
    # Puts [string] Value into key
    $byteArray = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $memStream = New-Object System.IO.MemoryStream (,$byteArray)
    Put-FromStream -Key $key -Perm $Perm -ContentType $ContentType -Stream $memStream -Length $byteArray.Count
    $memStream.Close()
}

function List-Keys([string]$prefix, [string]$delimiter, [string]$marker, [int]$maxKeys) {
    $params = @{}
    if ($prefix) { $params.Add('prefix', $prefix) }
    if ($delimiter) { $params.Add('delimiter', $delimiter) }
    if ($marker) { $params.Add('marker', $marker) }
    if (!$maxKeys) { $maxKeys = 1000 }
    if ($maxKeys -lt 1 -or $maxKeys -gt 1000) { throw 'Maxkeys must be between 1 and 1000, inclusive' }
    $params.Add('max-keys', $maxKeys.ToString())

    $result = Get-Text -Key '/' -Params $params
    #Write-Host $result
    $x = ([xml]$result).ListBucketResult
    $return = [PSCustomObject]@{
        Contents = @()
        CommonPrefixes = @()
        IsTruncated = $false
        NextMarker = $null
    }
    if ($x.IsTruncated -eq 'true') {
        $return.IsTruncated = $true
        $return.NextMarker = [string]$x.NextMarker
    }
    if ($x.Contents) {
        $x.Contents | % {
            $return.Contents += [PSCustomObject]@{
                Key = [string]$_.Key
                ETag = [string]$_.ETag
                LastModified = [datetime]::Parse($_.LastModified)
                Size = [uint64]$_.Size
            }
        }
    }
    if ($x.CommonPrefixes) {
        $x.CommonPrefixes | % { $return.CommonPrefixes += [string]$_.Prefix }
    }

    $return
}

function Remove-Key([string]$Key) {
    Run -method 'DELETE' -uri $Key
}
function Remove-Prefix([string]$Prefix) {
    if (!$Prefix) {
        $ans = Read-Host -Prompt 'Are you sure you want to delete everything in the bucket (y/N)'
        if ($ans -ne 'y') { return }
    }
    $doc = New-Object System.Xml.XmlDocument
    [void]$doc.AppendChild($doc.CreateXmlDeclaration("1.0","UTF-8",$null))
    $root = $doc.CreateElement('Delete')
    [void]$doc.AppendChild($root)
    $root.AppendChild($doc.CreateElement('Quiet')).InnerText = 'true'
    do {
        $result = List-Keys -prefix $Prefix -marker $marker
        $result.Contents | % {
            $ob = $root.AppendChild($doc.CreateElement('Object'))
            $ob.AppendChild($doc.CreateElement('Key')).InnerText = $_.Key
        }
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($doc.OuterXml)
        $md5 = New-Object System.Security.Cryptography.MD5CryptoServiceProvider
        $headers = @{'Content-MD5'= [Convert]::Tobase64String($md5.ComputeHash($bodyBytes)) }
        $ms = New-Object System.IO.MemoryStream (,$bodyBytes)
        Run -method 'POST' -uri '/' -params @{delete = ''} -contentLength $bodyBytes.Count -stream $ms -headers $headers
        $ms.Close()
        if ($result.IsTruncated) { $marker = $result.NextMarker }
    } while ($result.IsTruncated)
}

function Head-Key([string]$Key) {
    Run -method 'HEAD' -uri $key
}

Export-ModuleMember -Function Get-Bucket, Get-Text, Put-Text, Get-ToStream, Put-FromStream, Remove-Key, Remove-Prefix, List-Keys, Head-Key
