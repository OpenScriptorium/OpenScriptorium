# Build a composite favicon with the S nested inside the O.
#
# - O is the base layer at full size, dark ink
# - S is scaled down and centered inside the O, in rubric red
# - Both share the O's square canvas
#
# Run with: bundle exec ruby tools/letters/build-composite.rb

require "nokogiri"

ROOT = File.expand_path("../../..", __FILE__)

def load_paths(path)
  doc = Nokogiri::XML(File.read(path))
  doc.remove_namespaces!
  group = doc.at_xpath("//g")
  width  = doc.root["width"].to_f
  height = doc.root["height"].to_f
  transform = group["transform"]
  paths = group.xpath("./path").map(&:to_xml).join("\n")
  { width: width, height: height, transform: transform, paths: paths }
end

o = load_paths(File.join(ROOT, "app/assets/images/letters/dropcap-O.svg"))
s = load_paths(File.join(ROOT, "app/assets/images/letters/dropcap-S.svg"))

# Canvas is the O's bounding box
canvas_w = o[:width]
canvas_h = o[:height]

# S is scaled down small enough to sit cleanly in the center of the O,
# inside the inner clear area, without competing with the O's outer
# decorative frame.
s_scale = 0.40
s_target_w = canvas_w * s_scale
s_target_h = s[:height] * (s_target_w / s[:width])

# Center the scaled S on the canvas
s_x = (canvas_w - s_target_w) / 2.0
s_y = (canvas_h - s_target_h) / 2.0

ink_dark = "#1a1a1a"  # near-black ink
rubric   = "#9b2226"  # manuscript red

composite = <<~SVG
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <svg xmlns="http://www.w3.org/2000/svg"
       viewBox="0 0 #{canvas_w} #{canvas_h}"
       preserveAspectRatio="xMidYMid meet">
    <title>Open Scriptorium</title>

    <!-- O — full canvas, dark ink -->
    <g fill="#{ink_dark}">
      <g transform="#{o[:transform]}">
        #{o[:paths]}
      </g>
    </g>

    <!-- S — scaled down and centered inside the O, rubric red -->
    <g fill="#{rubric}"
       transform="translate(#{s_x} #{s_y}) scale(#{s_target_w / s[:width]})">
      <g transform="#{s[:transform]}">
        #{s[:paths]}
      </g>
    </g>
  </svg>
SVG

out_path = File.join(ROOT, "app/assets/images/letters/dropcap-OS.svg")
File.write(out_path, composite)
puts "Wrote #{out_path} (#{File.size(out_path)} bytes)"
puts "  canvas:  #{canvas_w}x#{canvas_h}"
puts "  S size:  #{s_target_w.round(1)}x#{s_target_h.round(1)} (#{(s_scale * 100).to_i}% of canvas width)"
puts "  S pos:   (#{s_x.round(1)}, #{s_y.round(1)})"
