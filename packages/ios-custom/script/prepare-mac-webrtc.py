#!/usr/bin/env python3
"""M147's macOS slice ships its binary but omits the public ObjC headers.

Repair the build product from the *same archive's* common headers. The
SPM artifact, its checksum, binary and iOS slices remain untouched. Only the
audio/data API used by VoiceTransport is exposed (no UIKit or video views).
"""
import os
from pathlib import Path
import re

products = Path(os.environ["BUILT_PRODUCTS_DIR"])
build = Path(os.environ["BUILD_DIR"])
derived = build.parents[1]
archive = derived / "SourcePackages/artifacts/webrtc/WebRTC/WebRTC.xcframework"
source = archive / "ios-arm64/WebRTC.framework/Headers"
target = products / "WebRTC.framework"
# Xcode's processed product is a copy; never repair the package-manager artifact.
assert target.resolve().is_relative_to(products.resolve())
headers = target / "Headers"
headers.mkdir(parents=True, exist_ok=True)
public = [
    "RTCAudioSource.h", "RTCAudioTrack.h", "RTCConfiguration.h", "RTCCryptoOptions.h",
    "RTCDataChannel.h", "RTCDataChannelConfiguration.h", "RTCIceCandidate.h",
    "RTCIceServer.h", "RTCMediaConstraints.h", "RTCMediaSource.h", "RTCMediaStream.h",
    "RTCMediaStreamTrack.h", "RTCPeerConnection.h", "RTCPeerConnectionFactory.h",
    "RTCRtpReceiver.h", "RTCRtpSender.h", "RTCRtpTransceiver.h", "RTCSSLAdapter.h",
    "RTCSessionDescription.h",
]

def copy_header(name):
    destination = headers / name
    content = (source / name).read_bytes()
    if destination.exists() and destination.read_bytes() == content:
        return
    destination.write_bytes(content)
    for dependency in re.findall(rb'#(?:import|include) [<"](?:WebRTC/)?(RTC[^>"/]+\.h)[>"]', content):
        copy_header(dependency.decode())

for name in public:
    copy_header(name)
umbrella = "\n".join(f'#import <WebRTC/{name}>' for name in public) + "\n"
if (headers / "WebRTC.h").read_text() != umbrella:
    (headers / "WebRTC.h").write_text(umbrella)
