namespace Witness.Core.Models;

public static class ProductModel
{
    public static ModelArtifact Default { get; } = new(
        Id: "whisper-large-v3-turbo-q5_0",
        Revision: "98aa99a0a9db05ae2342309f5096248665f7cba3",
        FileName: "ggml-large-v3-turbo-q5_0.bin",
        DownloadUri: new Uri(
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/98aa99a0a9db05ae2342309f5096248665f7cba3/ggml-large-v3-turbo-q5_0.bin"),
        SizeBytes: 574_041_195,
        Sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
        License: "MIT");
}
