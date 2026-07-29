"""Human labels for advertised mDNS service types (pure lookup; no I/O).

Deliberately conservative: only service types worth naming on a venue or office
segment appear here, and an unknown type is always shown verbatim by the caller.
The table adds context, it never hides or rewrites what was discovered.

Vendor service names change between product generations. Treat this as a
convenience layer, not an authority — confirm against vendor documentation
before drawing a conclusion from a label alone.
"""

from __future__ import annotations

# Keyed by service type with the transport, minus the .local suffix.
_SERVICES: dict[str, str] = {
    # Audio/video over IP — the reason an AV tech runs discover.
    "_ndi._tcp": "NDI video",
    "_netaudio-arc._udp": "Dante (routing control)",
    "_netaudio-cmc._udp": "Dante (device control)",
    "_netaudio-dbc._udp": "Dante (device broadcast)",
    "_netaudio-chan._udp": "Dante (channel names)",
    "_rtsp._tcp": "RTSP stream",
    "_onvif._tcp": "ONVIF camera",
    "_axis-video._tcp": "Axis camera",
    "_blackmagic._tcp": "Blackmagic device",
    # Consumer media, common on venue and guest segments.
    "_airplay._tcp": "AirPlay",
    "_raop._tcp": "AirPlay audio",
    "_googlecast._tcp": "Chromecast",
    "_spotify-connect._tcp": "Spotify Connect",
    "_sonos._tcp": "Sonos",
    "_hap._tcp": "HomeKit accessory",
    # Infrastructure.
    "_printer._tcp": "printer (LPD)",
    "_ipp._tcp": "printer (IPP)",
    "_ipps._tcp": "printer (IPP/TLS)",
    "_pdl-datastream._tcp": "printer (raw 9100)",
    "_smb._tcp": "SMB file share",
    "_afpovertcp._tcp": "AFP file share",
    "_ssh._tcp": "SSH",
    "_sftp-ssh._tcp": "SFTP",
    "_http._tcp": "HTTP",
    "_https._tcp": "HTTPS",
    "_workstation._tcp": "workstation",
    "_device-info._tcp": "device info",
}


def normalize_service(service: str) -> str:
    """Reduce a discovered PTR target to its bare service type for lookup."""
    name = service.strip().rstrip(".").lower()
    return name.removesuffix(".local").rstrip(".")


def label_service(service: str) -> str | None:
    """Friendly label for a service type, or None when it is not known."""
    return _SERVICES.get(normalize_service(service))


def describe_service(service: str) -> str:
    """Service type annotated with its label when one is known.

    Unknown types are returned unchanged, so nothing discovered is ever lost.
    """
    label = label_service(service)
    return f"{service} ({label})" if label else service


def media_services(services: list[str]) -> list[str]:
    """The subset whose labels name real-time AV transports (Dante, NDI).

    These are the flows that care about clocking, QoS and multicast handling,
    so their presence changes which follow-up checks are worth running.
    """
    out = []
    for s in services:
        label = label_service(s)
        if label and label.startswith(("Dante", "NDI")):
            out.append(s)
    return out
