#!/bin/bash
# Download the exact Nemotron 3 Core ML artifact used by the Notetaker dogfood
# build. Model weights are build inputs only and must never be committed.
set -euo pipefail

destination=${1:?usage: prepare_nemotron3_model.sh DESTINATION}
revision=25a90f97f254428d4b30374b76af9c74fdee8327
repository=https://huggingface.co/FluidInference/nemotron-3-diarization-coreml
model=Nemotron3Diarizer_c128_split_w8a8.mlmodelc
base="$repository/resolve/$revision"

mkdir -p "$destination/$model/analytics" "$destination/$model/weights"

fetch() {
    relative=$1
    expected=$2
    local_relative=${3:-$relative}
    target="$destination/$local_relative"
    if [ -f "$target" ] && [ "$(shasum -a 256 "$target" | awk '{print $1}')" = "$expected" ]; then
        return
    fi
    temporary="$target.download"
    curl -fL --retry 3 "$base/$relative" -o "$temporary"
    actual=$(shasum -a 256 "$temporary" | awk '{print $1}')
    [ "$actual" = "$expected" ] || {
        echo "Hash mismatch for $relative: expected $expected, got $actual" >&2
        exit 1
    }
    mv "$temporary" "$target"
}

fetch learnable_sil_emb.bin d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7
fetch pre_encode_proj_t.bin eb15b89e7af9813331a7d8db02e83e30bf97463d272c748e72086bafd4e81c60
fetch "split/$model/coremldata.bin" 777c6c6240baef5973b99b6984e9bb3a1f6a4812de28d3c65317be8911491421 "$model/coremldata.bin"
fetch "split/$model/model.mil" fdc429dae043fd0e10c9c91408a6002df6b90c71ef5c30877c56f7796abb6c53 "$model/model.mil"
fetch "split/$model/analytics/coremldata.bin" 9522ac23edf90deb9bc4d3ef97ca435a90df499d346c4806351784b5a8decb60 "$model/analytics/coremldata.bin"
fetch "split/$model/weights/weight.bin" 9a4c5de6ba011560713206b76c357d99ee596d1f1a58c66368b82834f9e12f95 "$model/weights/weight.bin"

printf '%s\n' "$destination"
