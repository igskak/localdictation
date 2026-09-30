# Third-party dependencies and notices

Versions are locked in `Directory.Packages.props`, `.config/dotnet-tools.json`, `global.json`, and `native/Witness.Native/CMakeLists.txt`. Runtime dependencies are included only where a standard framework cannot satisfy the requirement.

| Component | Exact version / commit | Source | License | Why it is needed | Distribution notes |
| --- | --- | --- | --- | --- | --- |
| .NET SDK / Windows Desktop Runtime | SDK 10.0.401; restored Windows x64 runtime packs 10.0.12 | Microsoft .NET | Runtime-pack license and bundled third-party notices | C# compiler, WPF runtime, and self-contained x64 deployment | The W8 kit generator reads the exact runtime-pack versions from restore assets and appends their own license/notice files. |
| MSTest | 4.4.1 | NuGet `MSTest` | MIT | Deterministic Core/platform tests; development-only | Not shipped with the application. |
| Microsoft.NET.Test.Sdk | 18.10.1 | NuGet | MIT | Test discovery/runner; development-only | Not shipped with the application. |
| NSec.Cryptography | 26.4.0, source commit `02c51bb20a7b6accc96e74ecab6e2659cc1f5c63` | https://github.com/ektrah/nsec | MIT | Audited Ed25519 verification for license and update envelopes | Carries the notices for libsodium, RFC 6234, .NET Runtime, and the Hex/Base64 implementation. |
| libsodium | 1.0.22 | https://github.com/jedisct1/libsodium | ISC | Transitive native implementation used by NSec | Ship its ISC notice. |
| Velopack library and `vpk` | 1.2.158, source commit `3c7f52c1bf17d10ad21b794b006d5ebd1a879a3b` | https://github.com/velopack/velopack | MIT | Installer/update lifecycle; standard frameworks do not provide a safe unpackaged desktop updater | The app additionally verifies an Ed25519 manifest and exact package before Velopack receives it. No transitive runtime package applies on `net10.0`. |
| whisper.cpp | v1.9.4, commit `927cfce34f31707e17f2bff35c349632fb9e2c3a` | https://github.com/ggml-org/whisper.cpp | MIT | Local in-process multilingual speech recognition with CPU fallback and optional Vulkan | ggml backends/notices must be included in the final package. |
| Whisper large-v3-turbo q5_0 GGML model | artifact revision `98aa99a0a9db05ae2342309f5096248665f7cba3`, SHA-256 `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2` | https://huggingface.co/ggerganov/whisper.cpp | MIT | Pinned multilingual product model for local recognition | Downloaded separately after disclosure; not stored in source control or build artifacts. CI may retain the same public, hash-addressed file in the private Actions cache. Synthetic DE/EN/RU/UK regression passed; real-speech and physical performance remain W8 QA. |
| eSpeak NG | 1.52.0 MSI, SHA-256 `7f673c709ea5dd579d3b5ebb98688cc575328a6ab7438d2bc405b88cedaeafb9` | https://github.com/espeak-ng/espeak-ng/releases/tag/1.52.0 | GPL-3.0-or-later | Generates non-user DE/EN/RU speech fixtures inside W3 CI | Development-only. It is never linked, bundled, or shipped; generated WAV files are deleted before artifact assembly. |
| Piper | `2023.11.14-2`, commit `38917ffd8c0e219c6581d73e07b30ef1d572fce1`, Windows archive SHA-256 `f3c58906402b24f3a96d92145f58acba6d86c9b5db896d207f78dc80811efcea` | https://github.com/rhasspy/piper/releases/tag/2023.11.14-2 | MIT; binary archive includes GPL-3.0-or-later eSpeak NG and MIT ONNX Runtime | Generates a more representative non-user neural Ukrainian fixture after eSpeak speech failed the pinned Whisper language gate | Development-only and never shipped. The archive, model, config, text and generated WAV are deleted before artifact assembly. Because the archive is only executed in CI and not redistributed, its bundled licenses do not enter the beta package; retain this inventory and upstream notices for CI provenance. |
| Piper `uk_UA-ukrainian_tts-medium` voice | revision `375a0fe641dea077c2a47b4e9a056d6da521eed3`; model SHA-256 `7920419ac5f6fd8b6450520f24b52ed5a319cb53dd018fbcd71c9e079cbac84f`; config SHA-256 `4e96e72917ca9b94edc77d6ccfee03a73f450ba2fc1ca93c2e562bc014e5aa55` | https://huggingface.co/rhasspy/piper-voices/tree/375a0fe641dea077c2a47b4e9a056d6da521eed3/uk/uk_UA/ukrainian_tts/medium | CC0-1.0 (`NabuCasa/voice-datasets`) | Supplies the pinned neural voice used for the synthetic Ukrainian W3 fixture | Development-only and never shipped or cached in the product artifact. The voice files and generated WAV are deleted before artifact assembly. |

## Required bundled notices

`Windows/tools/New-W8BetaKit.ps1` includes this complete shipping-component
section and appends the exact license plus third-party-notice files from the
restored Windows x64 .NET runtime packs. Development-only tools in the inventory
above are not shipped and therefore are not repeated in the beta kit.

### NSec.Cryptography 26.4.0 (MIT)

MIT License

Copyright (c) 2026 Klaus Hartke

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### libsodium (ISC)

Copyright (c) 2013-2026 Frank Denis

Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

### RFC 6234 derived code (Simplified BSD)

Copyright (c) 2011 IETF Trust and the persons identified as authors of the code. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that source redistributions retain the copyright notice, conditions, and disclaimer; binary redistributions reproduce them in documentation/materials; and the names of Internet Society, IETF, IETF Trust, and contributors are not used for endorsement without permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" WITHOUT EXPRESS OR IMPLIED WARRANTIES, INCLUDING MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. IN NO EVENT SHALL THEY BE LIABLE FOR DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES, HOWEVER CAUSED.

### .NET Runtime derived code in NSec (MIT)

Copyright (c) .NET Foundation and Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### Hex and Base64 implementation in NSec (MIT)

Copyright (c) 2014 Steve Thomas

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### Velopack 1.2.158 (MIT)

Copyright © 2021 Caelan Sayler
Copyright © 2024 Velopack Ltd.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### whisper.cpp v1.9.4 and ggml (MIT)

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### OpenAI Whisper model (MIT)

Copyright (c) 2022 OpenAI

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
