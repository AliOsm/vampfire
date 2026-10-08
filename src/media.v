module main

import json2 as json
import math
import os
import stbi

// Runs in the same executable's bounded media subprocess. A malformed decoder
// input cannot consume the server's memory, and no database is opened here.
fn thumbnail_image(input string, output string) ! {
	bytes := os.read_bytes(input)!
	if bytes.len > upload_limit { return error('Image is too large.') }
	// Preserve ffmpeg's orientation/color handling for metadata-bearing photos.
	if bytes.bytestr().contains('Exif\x00\x00') || bytes.bytestr().contains('eXIf') {
		return error('Image metadata requires ffmpeg.')
	}
	info := stbi.info_from_memory(bytes.data, bytes.len)!
	if info.width < 1 || info.height < 1 || info.width > 8192 || info.height > 8192 || i64(info.width) * info.height > 20000000 {
		return error('Image dimensions exceed the preview limit.')
	}
	image := stbi.load_from_memory(bytes.data, bytes.len, desired_channels: 3)!
	defer { image.free() }
	scale := math.min(1, math.min(f64(1200) / info.width, f64(800) / info.height))
	width := math.max(1, int(info.width * scale))
	height := math.max(1, int(info.height * scale))
	if width == image.width && height == image.height {
		stbi.stbi_write_jpg(output, width, height, 3, image.data, 85)!
	} else {
		resized := stbi.resize_uint8(image, width, height)!
		defer { resized.free() }
		stbi.stbi_write_jpg(output, width, height, 3, resized.data, 85)!
	}
	println(json.encode(MediaInfo{ streams: [MediaStream{ width: info.width, height: info.height }] }))
}
