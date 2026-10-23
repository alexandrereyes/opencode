#!/usr/bin/env python3
"""Regenerate bundled licenses from pinned dependency sources (never downloads models)."""
from pathlib import Path
import urllib.request

base = 'https://raw.githubusercontent.com/FluidInference/FluidAudio/503b4bd1bbf7220882de39fe8ae6716aae4132da/'
sources = [
    ('FluidAudio 0.17.7 — Apache License 2.0', base + 'LICENSE'),
    ('FluidAudio / fastcluster', base + 'ThirdPartyLicenses/fastcluster-LICENSE.md'),
    ('FluidAudio / NeMo text processing', base + 'ThirdPartyLicenses/NemoTextProcessing-LICENSE.md'),
    ('FluidAudio / Japanese G2P', base + 'ThirdPartyLicenses/JapaneseG2P-LICENSE.md'),
    ('FluidAudio / Spanish and French G2P', base + 'ThirdPartyLicenses/KokoroAneSpanishFrenchG2P-LICENSE.md'),
    ('FluidAudio / VBx', base + 'ThirdPartyLicenses/vbx-LICENSE.md'),
    ('Parakeet Ultra — Creative Commons Attribution 4.0 International',
     'https://raw.githubusercontent.com/idleberg/Creative-Commons-4.0-Markdown/master/4.0/by.markdown'),
]
header = '''Transcrição no aparelho — avisos de terceiros

FluidAudio 0.17.7 (503b4bd1bbf7220882de39fe8ae6716aae4132da)
https://github.com/FluidInference/FluidAudio
Copyright FluidInference and contributors. Apache License 2.0.

Parakeet Ultra, by moondream, post-training of NVIDIA parakeet-tdt-0.6b-v3.
CoreML conversion by FluidInference. CC BY 4.0. Unmodified model weights.
https://huggingface.co/moondream/parakeet-ultra
https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
https://huggingface.co/FluidInference/parakeet-ultra-coreml
Pinned model revision: 95eaa59a39d4394f047a4dc5cce480388a60d1b6.
Weights are downloaded only after consent, never bundled in this app.
No endorsement by the authors is implied.

The recording gesture, PCM capture, preview finalization and verified model
download are adapted from Alexandre Reyes Martins's Abacato v2 iOS app.
Adaptations: local draft transcription, no audio upload or automatic sending,
OpenCode themes, iOS 27 notifications, model consent/removal and draft retention.

'''
parts = [header]
for title, url in sources:
    with urllib.request.urlopen(url, timeout=60) as response:
        parts += ['\n' + '=' * 72 + '\n' + title + '\n' + url + '\n\n', response.read().decode()]
path = Path(__file__).resolve().parents[1] / 'OpenCode/Resources/TranscriptionNotices.txt'
path.write_text(''.join(parts))
print(path)
