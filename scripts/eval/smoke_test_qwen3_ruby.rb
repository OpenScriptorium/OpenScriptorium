#!/usr/bin/env ruby
# Ruby-side smoke test for the fused fp16 Qwen3-Embedding ONNX model.
#
# Loads vendor/models/qwen3_embed_fused_fp16/, encodes a list of test queries,
# writes vectors as JSON to /tmp/ruby_qwen3_vecs.json. A separate Python script
# encodes the same queries via Python onnxruntime and compares cosine similarity.
#
# Usage: bundle exec ruby scripts/eval/smoke_test_qwen3_ruby.rb

require "bundler/setup"
require "onnxruntime"
require "tokenizers"
require "json"

MODEL_DIR = File.expand_path("../../vendor/models/qwen3_embed_fused_fp16", __dir__)
TEST_QUERIES = [
  "In the beginning God created the heavens and the earth",
  "Throne Room Vision",
  "Faith Without Works Is Dead",
  "ἀγάπη",
  "שָׁלוֹם",
  "Love your neighbor as yourself",
  "Beatitudes",
  "Seven Churches of Asia",
  "King of Kings",
  "Now the earth was formless and void",
]

puts "Loading model from #{MODEL_DIR}..."
puts "  ORT gem: #{OnnxRuntime::VERSION}" if defined?(OnnxRuntime::VERSION)

t0 = Time.now
session = OnnxRuntime::InferenceSession.new(File.join(MODEL_DIR, "model.onnx"))
tokenizer = Tokenizers::Tokenizer.from_file(File.join(MODEL_DIR, "tokenizer.json"))
puts "  loaded in #{(Time.now - t0).round(2)}s"
puts "  inputs:  #{session.inputs.map { |i| i[:name] }}"
puts "  outputs: #{session.outputs.map { |o| o[:name] }}"

# Tokenize batch
puts "\nTokenizing #{TEST_QUERIES.size} queries..."
encodings = tokenizer.encode_batch(TEST_QUERIES)

# Pad to longest in batch
max_len = encodings.map { |e| e.ids.length }.max
puts "  max_len in batch: #{max_len}"

ids_2d = encodings.map { |e| e.ids + [tokenizer.token_to_id("<|endoftext|>") || 0] * (max_len - e.ids.length) }
mask_2d = encodings.map { |e| e.attention_mask + [0] * (max_len - e.attention_mask.length) }

puts "\nRunning ONNX inference..."
t0 = Time.now
result = session.run(nil, {
  "input_ids" => ids_2d,
  "attention_mask" => mask_2d,
})
puts "  inference took #{(Time.now - t0).round(2)}s"

out_names = session.outputs.map { |o| o[:name] }
out_map = out_names.zip(result).to_h

# sentence_embedding is the pooled+normalized output
sent_emb = out_map["sentence_embedding"]
puts "\nsentence_embedding shape: [#{sent_emb.length}, #{sent_emb.first.length}]"
puts "first vector first 8 dims: #{sent_emb.first.first(8).map { |v| v.round(6) }}"

# Save to JSON for Python comparison
output = {
  texts: TEST_QUERIES,
  vectors: sent_emb,
}
output_path = "/tmp/ruby_qwen3_vecs.json"
File.write(output_path, JSON.dump(output))
puts "\nWrote #{output_path}"
