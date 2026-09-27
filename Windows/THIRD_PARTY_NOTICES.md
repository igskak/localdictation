# Third-party dependencies and notices

Versions are locked in `Directory.Packages.props`, `.config/dotnet-tools.json`, `global.json`, and `native/Witness.Native/CMakeLists.txt`. Runtime dependencies are included only where a standard framework cannot satisfy the requirement.

| Component | Exact version / commit | Source | License | Why it is needed | Distribution notes |
| --- | --- | --- | --- | --- | --- |
| .NET SDK / Windows Desktop Runtime | 10.0.401 | Microsoft .NET | MIT and bundled third-party notices | C# compiler, WPF runtime, and self-contained x64 deployment | Include the .NET runtime notices produced by the final publish/package pipeline. |
| MSTest | 4.4.1 | NuGet `MSTest` | MIT | Deterministic Core/platform tests; development-only | Not shipped with the application. |
| Microsoft.NET.Test.Sdk | 18.10.1 | NuGet | MIT | Test discovery/runner; development-only | Not shipped with the application. |
| NSec.Cryptography | 26.4.0, source commit `02c51bb20a7b6accc96e74ecab6e2659cc1f5c63` | https://github.com/ektrah/nsec | MIT | Audited Ed25519 verification for license and update envelopes | Carries the notices for libsodium, RFC 6234, .NET Runtime, and the Hex/Base64 implementation. |
| libsodium | 1.0.22 | https://github.com/jedisct1/libsodium | ISC | Transitive native implementation used by NSec | Ship its ISC notice. |
| Velopack library and `vpk` | 1.2.158, source commit `3c7f52c1bf17d10ad21b794b006d5ebd1a879a3b` | https://github.com/velopack/velopack | MIT | Installer/update lifecycle; standard frameworks do not provide a safe unpackaged desktop updater | The app additionally verifies an Ed25519 manifest and exact package before Velopack receives it. No transitive runtime package applies on `net10.0`. |
| whisper.cpp | v1.9.4, commit `927cfce34f31707e17f2bff35c349632fb9e2c3a` | https://github.com/ggml-org/whisper.cpp | MIT | Local in-process multilingual speech recognition with CPU fallback and optional Vulkan | ggml backends/notices must be included in the final package. |
| Whisper large-v3-turbo q5_0 GGML model candidate | artifact revision `98aa99a0a9db05ae2342309f5096248665f7cba3`, SHA-256 `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2` | https://huggingface.co/ggerganov/whisper.cpp | MIT | Pinned multilingual product-model candidate for local recognition | Downloaded separately after disclosure; not stored in source control or ordinary CI artifacts. Selection remains conditional on W3 language and performance validation. |

## Required bundled notices

### libsodium (ISC)

Copyright (c) 2013-2026 Frank Denis

Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

### RFC 6234 derived code (Simplified BSD)

Copyright (c) 2011 IETF Trust and the persons identified as authors of the code. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that source redistributions retain the copyright notice, conditions, and disclaimer; binary redistributions reproduce them in documentation/materials; and the names of Internet Society, IETF, IETF Trust, and contributors are not used for endorsement without permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" WITHOUT EXPRESS OR IMPLIED WARRANTIES, INCLUDING MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. IN NO EVENT SHALL THEY BE LIABLE FOR DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES, HOWEVER CAUSED.

The full MIT texts for .NET, MSTest, NSec, Velopack, whisper.cpp, and derived .NET/Hex/Base64 code will be copied verbatim into the generated `THIRD_PARTY_NOTICES.txt` before an external beta artifact is declared ready.
