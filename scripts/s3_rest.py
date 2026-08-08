"""
s3_rest.py — dependency-light S3 access over the REST API with AWS Signature V4.

Pure `requests` + stdlib (`hashlib`, `hmac`, `xml`, `urllib`) — **no boto3**. This is the reference
implementation that is embedded (verbatim function bodies) into the Fabric notebooks nb_pipeline_01/nb_pipeline_02 so
the pipeline can read directly from any S3-compatible endpoint (AWS S3, Cohesity, MinIO, ...) without
a `%pip install` in the Fabric job runtime.

Works against:
  * AWS S3            endpoint = https://s3.<region>.amazonaws.com   (path-style) or virtual-hosted
  * S3-compatible     endpoint = https://<host>[:port]              (path-style, self-signed ok)

Only GET/HEAD are needed by the pipeline (list + read), so the payload is always empty and the
signed payload hash is the SHA256 of the empty string.
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import hmac
import urllib.parse as _url
import xml.etree.ElementTree as _ET

import requests

_EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()
_UNRESERVED = "/"  # keep path separators when encoding an object key


def _sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def _signing_key(secret: str, datestamp: str, region: str, service: str) -> bytes:
    k_date = _sign(("AWS4" + secret).encode("utf-8"), datestamp)
    k_region = hmac.new(k_date, region.encode("utf-8"), hashlib.sha256).digest()
    k_service = hmac.new(k_region, service.encode("utf-8"), hashlib.sha256).digest()
    return hmac.new(k_service, b"aws4_request", hashlib.sha256).digest()


def _canonical_query(params: dict | None) -> str:
    if not params:
        return ""
    items = []
    for k in sorted(params):
        v = "" if params[k] is None else str(params[k])
        items.append(f"{_url.quote(str(k), safe='')}={_url.quote(v, safe='')}")
    return "&".join(items)


def _endpoint_parts(endpoint_url: str, bucket: str, key: str, addressing: str):
    """Return (host, canonical_uri, request_url) for path- or virtual-hosted style."""
    p = _url.urlparse(endpoint_url)
    scheme = p.scheme or "https"
    ep_host = p.netloc
    enc_key = _url.quote(key, safe=_UNRESERVED)
    if addressing == "virtual":
        host = f"{bucket}.{ep_host}"
        canonical_uri = "/" + enc_key
    else:  # path-style
        host = ep_host
        canonical_uri = "/" + bucket + ("/" + enc_key if key else "")
    request_url = f"{scheme}://{host}{canonical_uri}"
    return host, canonical_uri, request_url


def _signed_headers(method, host, canonical_uri, params, region, ak, sk, service="s3"):
    now = _dt.datetime.now(_dt.timezone.utc)
    amzdate = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")
    canonical_qs = _canonical_query(params)
    canonical_headers = (
        f"host:{host}\n"
        f"x-amz-content-sha256:{_EMPTY_SHA256}\n"
        f"x-amz-date:{amzdate}\n"
    )
    signed_headers = "host;x-amz-content-sha256;x-amz-date"
    canonical_request = "\n".join(
        [method, canonical_uri, canonical_qs, canonical_headers, signed_headers, _EMPTY_SHA256]
    )
    scope = f"{datestamp}/{region}/{service}/aws4_request"
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amzdate,
            scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )
    signature = hmac.new(
        _signing_key(sk, datestamp, region, service),
        string_to_sign.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    authorization = (
        f"AWS4-HMAC-SHA256 Credential={ak}/{scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )
    return {
        "Authorization": authorization,
        "x-amz-date": amzdate,
        "x-amz-content-sha256": _EMPTY_SHA256,
    }


def s3_signed_get(endpoint_url, bucket, key, region, ak, sk, *, params=None,
                  addressing="path", verify=True, stream=False, timeout=(10, 120)):
    """Perform a SigV4-signed GET (or list when key='' + list-type params). Returns a Response."""
    host, canonical_uri, url = _endpoint_parts(endpoint_url, bucket, key, addressing)
    headers = _signed_headers("GET", host, canonical_uri, params, region, ak, sk)
    resp = requests.get(url, headers=headers, params=params, verify=verify,
                        stream=stream, timeout=timeout)
    # S3 signals a wrong-region/wrong-endpoint with a 3xx + an error body (no Location header), which
    # requests does not follow. Surface it loudly instead of silently parsing an empty result.
    if 300 <= resp.status_code < 400:
        raise requests.HTTPError(
            f"{resp.status_code} redirect from S3 (wrong region/endpoint?): {resp.text[:300]}",
            response=resp)
    return resp


def s3_list_objects(endpoint_url, bucket, region, ak, sk, *, prefix="",
                    addressing="path", verify=True, timeout=(10, 60)):
    """List all objects under `prefix` via ListObjectsV2, following continuation tokens.

    Returns a list of dicts: {key, size, last_modified, etag}.
    """
    ns = "{http://s3.amazonaws.com/doc/2006-03-01/}"
    out = []
    token = None
    while True:
        params = {"list-type": "2", "prefix": prefix, "max-keys": "1000"}
        if token:
            params["continuation-token"] = token
        r = s3_signed_get(endpoint_url, bucket, "", region, ak, sk,
                          params=params, addressing=addressing, verify=verify, timeout=timeout)
        r.raise_for_status()
        root = _ET.fromstring(r.content)
        for c in root.findall(f"{ns}Contents"):
            key = c.findtext(f"{ns}Key")
            if key is None or key.endswith("/"):
                continue  # skip folder placeholder keys
            out.append({
                "key": key,
                "size": int(c.findtext(f"{ns}Size") or 0),
                "last_modified": c.findtext(f"{ns}LastModified"),
                "etag": (c.findtext(f"{ns}ETag") or "").strip('"'),
            })
        truncated = (root.findtext(f"{ns}IsTruncated") or "false").lower() == "true"
        token = root.findtext(f"{ns}NextContinuationToken")
        if not truncated or not token:
            break
    return out


def s3_get_bytes(endpoint_url, bucket, key, region, ak, sk, *,
                 addressing="path", verify=True, timeout=(10, 300)):
    r = s3_signed_get(endpoint_url, bucket, key, region, ak, sk,
                      addressing=addressing, verify=verify, timeout=timeout)
    r.raise_for_status()
    return r.content


def s3_head_metadata(endpoint_url, bucket, key, region, ak, sk, *,
                     addressing="path", verify=True, timeout=(10, 30)):
    """HEAD an object; return user metadata (x-amz-meta-*) + size + last-modified. Best-effort."""
    host, canonical_uri, url = _endpoint_parts(endpoint_url, bucket, key, addressing)
    headers = _signed_headers("HEAD", host, canonical_uri, None, region, ak, sk)
    r = requests.head(url, headers=headers, verify=verify, timeout=timeout)
    r.raise_for_status()
    meta = {k[len("x-amz-meta-"):].lower(): v
            for k, v in r.headers.items() if k.lower().startswith("x-amz-meta-")}
    return {
        "meta": meta,
        "size": int(r.headers.get("Content-Length", 0) or 0),
        "last_modified": r.headers.get("Last-Modified"),
    }
