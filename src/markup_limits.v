module main

// Bound work before handing input to the DOM parser. This only rejects excess
// complexity; render_rich remains responsible for sanitizing the parsed tree.
fn check_markup_complexity(source string) ! {
	mut stack := []string{}
	mut i := 0
	for i < source.len {
		if source[i] != `<` {
			i++
			continue
		}
		if source[i..].starts_with('<!--') {
			end := source[i + 4..].index('-->') or { return }
			i += end + 7
			continue
		}
		start := i
		i++
		closing := i < source.len && source[i] == `/`
		if closing { i++ }
		name_start := i
		for i < source.len && (source[i].is_alnum() || source[i] in [`-`, `:`, `!`]) { i++ }
		if i == name_start { continue }
		name := source[name_start..i].to_lower()
		mut quote := u8(0)
		mut tokens := 0
		mut blank := true
		for i < source.len {
			ch := source[i]
			if quote != 0 {
				if ch == quote { quote = 0 }
			} else if ch == `>` {
				break
			} else if ch in [`'`, `"`] {
				quote = ch
			} else if ch.is_space() {
				blank = true
			} else if blank {
				tokens++
				blank = false
			}
			if tokens > 128 || i - start > 8192 {
				return error_with_code('This message contains too many tag attributes.', 422)
			}
			i++
		}
		self_closing := i > 0 && source[i - 1] == `/`
		i++
		if closing {
			for j := stack.len - 1; j >= 0; j-- {
				if stack[j] == name {
					stack = stack[..j].clone()
					break
				}
			}
		} else if !self_closing && name !in ['area', 'base', 'br', 'col', 'embed', 'hr', 'img',
			'input', 'link', 'meta', 'param', 'source', 'track', 'wbr', '!doctype'] {
			stack << name
			if stack.len > 30 { return error_with_code('This message is nested too deeply.', 422) }
		}
	}
}
