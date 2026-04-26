require "singleton"
require "onnxruntime"
require "tokenizers"

module Search
  # Singleton query-side encoder.
  #
  # Loads the fused fp16 Qwen3-Embedding-0.6B ONNX export. The exported graph
  # already does mean-pooling + L2 normalization on its `sentence_embedding`
  # output, so we just feed in tokenized text and read the vector.
  #
  # Qwen3-Embedding is asymmetric: queries get an instruction prefix, documents
  # don't. Our corpus was encoded WITHOUT a prefix (documents), so queries here
  # get the standard "query" prompt from the model's
  # config_sentence_transformers.json.
  class EmbeddingEncoder
    include Singleton

    MODEL_DIR = Rails.root.join("vendor/models/qwen3_embed_fused_fp16").to_s

    # Standard Qwen3-Embedding query prompt (sentence-transformers
    # `prompt_name="query"`). Empty for documents — match the corpus encoding.
    QUERY_PROMPT_PREFIX = "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery: ".freeze

    # Truncate inputs after this many tokens. The corpus was encoded with
    # max_seq_length=256 on Modal; queries are much shorter in practice.
    MAX_LEN = 256

    EMBEDDING_DIM = 1024

    def initialize
      @mutex = Mutex.new
      @session = nil
      @tokenizer = nil
    end

    # Encode a string into a 1024-dim L2-normalized vector.
    #
    # Qwen3-Embedding is asymmetric: queries get an instruction prefix,
    # documents don't. The corpus was encoded as documents (no prefix), so
    # query-time text gets the prompt prepended for matching to work.
    #
    # @param prompt [Symbol] :query (default — Instruct prefix applied) or
    #   :document (raw text, no prefix). Use :document for one-time corpus
    #   encoding (e.g. pericope names) so the indexed and query-time forms
    #   share the same encoding.
    def encode(text, prompt: :query)
      return nil unless model_available?

      @mutex.synchronize do
        load_model! unless @session
        run_inference(text, prompt: prompt)
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
    end

    def run_inference(text, prompt: :query)
      input = prompt == :query ? "#{QUERY_PROMPT_PREFIX}#{text}" : text
      encoding = @tokenizer.encode(input)
      ids = encoding.ids
      mask = encoding.attention_mask

      if ids.length > MAX_LEN
        ids = ids.first(MAX_LEN)
        mask = mask.first(MAX_LEN)
      end

      result = @session.run(nil, {
        "input_ids" => [ids],
        "attention_mask" => [mask],
      })

      out_names = @session.outputs.map { |o| o[:name] }
      out_map = out_names.zip(result).to_h

      # `sentence_embedding` is already mean-pooled + L2-normalized in the
      # exported graph (Optimum sentence-transformers feature-extraction task).
      out_map.fetch("sentence_embedding").first
    end
  end
end
