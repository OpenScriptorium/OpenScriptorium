require "singleton"
require "onnxruntime"
require "tokenizers"

module Search
  class EmbeddingEncoder
    include Singleton

    MODEL_DIR = Rails.root.join("tmp/embedding_model/labse_scripture_onnx").to_s

    def initialize
      @mutex = Mutex.new
      @session = nil
      @tokenizer = nil
      @dense_weight = nil
      @dense_bias = nil
    end

    def encode(text)
      return nil unless model_available?

      @mutex.synchronize do
        load_model! unless @session
        run_inference(text)
      end
    rescue => e
      Rails.logger.warn("[EmbeddingEncoder] encode failed: #{e.message}")
      nil
    end

    def model_available?
      File.exist?(File.join(MODEL_DIR, "model.onnx"))
    end

    private

    def load_model!
      @tokenizer = Tokenizers::Tokenizer.from_file(File.join(MODEL_DIR, "tokenizer.json"))
      @session = OnnxRuntime::InferenceSession.new(File.join(MODEL_DIR, "model.onnx"))

      # Load dense layer weights (768x768 float32, row-major)
      w_bytes = File.binread(File.join(MODEL_DIR, "dense_weight.bin"))
      @dense_weight = w_bytes.unpack("e*").each_slice(768).to_a  # 768 rows of 768

      b_bytes = File.binread(File.join(MODEL_DIR, "dense_bias.bin"))
      @dense_bias = b_bytes.unpack("e*")  # 768 floats
    end

    def run_inference(text)
      # Tokenize
      encoding = @tokenizer.encode(text)
      ids = encoding.ids
      mask = encoding.attention_mask
      type_ids = encoding.type_ids

      # Run ONNX model — needs 2D arrays [batch, seq]
      output = @session.run(nil, {
        "input_ids" => [ids],
        "attention_mask" => [mask],
        "token_type_ids" => [type_ids]
      })

      hidden = output[0][0]  # [seq_len, 768]
      seq_len = ids.length

      # Mean pooling (masked)
      pooled = Array.new(768, 0.0)
      mask_sum = mask.sum.to_f
      seq_len.times do |i|
        next if mask[i] == 0
        768.times { |j| pooled[j] += hidden[i][j] }
      end
      pooled.map! { |v| v / mask_sum }

      # Dense layer: tanh(pooled @ W^T + bias)
      dense_out = Array.new(768) do |i|
        sum = @dense_bias[i]
        768.times { |j| sum += pooled[j] * @dense_weight[i][j] }
        Math.tanh(sum)
      end

      # L2 normalize
      norm = Math.sqrt(dense_out.sum { |v| v * v })
      dense_out.map! { |v| v / norm }

      dense_out
    end
  end
end
