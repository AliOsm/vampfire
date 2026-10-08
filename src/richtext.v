module main

import encoding.html as entities
import net.html
import strings
import strconv

fn escape(value string) string { return entities.escape(value) }

// Only pass complete named references to the library decoder. Decode numeric
// references as Unicode scalar values, and preserve ordinary literal '&' text.
fn unescape_html(value string) string {
	if !value.contains('&') { return value }
	mut out := strings.new_builder(value.len)
	mut i := 0
	for i < value.len {
		if value[i] == `&` {
			mut end := i + 1
			for end < value.len && end - i < 36 && value[end] != `;` && (value[end].is_alnum() || value[end] == `#`) {
				end++
			}
			if end < value.len && value[end] == `;` && end > i + 1 {
				entity := value[i..end + 1]
				if entity.starts_with('&#') {
					hex := entity.starts_with('&#x') || entity.starts_with('&#X')
					digits := entity[if hex { 3 } else { 2 }..entity.len - 1]
					point := strconv.parse_uint(digits, if hex { 16 } else { 10 }, 32) or { u64(0) }
					if point > 0 && point <= 0x10ffff && !(point >= 0xd800 && point <= 0xdfff) {
						out.write_string(rune(point).str())
					} else {
						out.write_string(entity)
					}
				} else {
					out.write_string(entities.unescape(entity, all: true))
				}
				i = end + 1
				continue
			}
		}
		out.write_u8(value[i])
		i++
	}
	return out.str()
}

struct RichText {
	html     string
	plain    string
	mentions []int
}

fn rich_text(source string) !RichText {
	return rich_text_named(source, {})
}

fn room_rich_text(db &Database, room_id int, source string) !RichText {
	if !source.contains('data-mention') { return rich_text(source) }
	mut names := map[int]string{}
	if source.contains('data-mention') {
		for row in query(db, 'SELECT u.id,u.name FROM users u JOIN memberships m ON m.user_id=u.id WHERE m.room_id=?', room_id.str())! {
			names[row.get_int('id')] = row.get_string('name')
		}
	}
	return rich_text_named(source, names)
}

fn rich_text_named(source string, names map[int]string) !RichText {
	if source.len > 32000 {
		return error_with_code('Messages can contain up to 32 KB of rich text.', 422)
	}
	if source.count('<') > 1000 {
		return error_with_code('This message contains too much markup.', 422)
	}
	// Parse a fragment beneath an inert root so adjacent top-level elements and
	// text before/after them remain siblings in V's document-oriented parser.
	dom := html.parse('<vampfire-root>${source}</vampfire-root>')
	mut out := strings.new_builder(source.len)
	mut plain := strings.new_builder(source.len)
	mut mentions := []int{}
	render_rich(dom.get_root(), mut out, mut plain, mut mentions, names, 0)!
	return RichText{ html: out.str(), plain: plain.str().trim_space(), mentions: mentions }
}

fn render_rich(tag &html.Tag, mut out strings.Builder, mut plain strings.Builder, mut mentions []int, names map[int]string, depth int) ! {
	if depth > 32 { return error_with_code('This message is nested too deeply.', 422) }
	name := tag.name.to_lower()
	if name in ['script', 'style', 'iframe', 'object', 'embed', 'svg', 'math', 'template', 'form',
		'input'] {
		return
	}
	if name == 'text' {
		value := unescape_html(tag.text())
		out.write_string(escape(value))
		plain.write_string(value)
		return
	}
	allowed := name in ['p', 'div', 'br', 'strong', 'b', 'em', 'i', 'u', 's', 'del', 'mark', 'code',
		'pre', 'blockquote', 'ul', 'ol', 'li', 'h1', 'h2', 'h3', 'a', 'span', 'table', 'thead',
		'tbody', 'tfoot', 'tr', 'th', 'td', 'hr']
	mut attrs := ''
	if name == 'pre' {
		language := tag.attributes['data-language'] or { '' }
		if language.len > 0 && language.len <= 30 && language.bytes().all(it.is_alnum() || it in [
			`-`,
			`_`,
		]) {
			attrs = ' data-language="${escape(language)}"'
		}
	}
	if name == 'a' {
		href := unescape_html(tag.attributes['href'] or { '' }).trim_space()
		if href.to_lower().starts_with('https://') || href.to_lower().starts_with('http://') || href.starts_with('mailto:') {
			attrs = ' href="${escape(href)}" rel="noopener noreferrer" target="_blank"'
		}
	}
	if name == 'span' {
		id := (tag.attributes['data-mention'] or { '' }).int()
		if id > 0 {
			attrs = ' class="mention" data-mention="${id}"'
			if id !in mentions { mentions << id }
			if person_name := names[id] {
				out.write_string('<span${attrs}>@${escape(person_name)}</span>')
				plain.write_string('@' + person_name)
				return
			}
		}
	}
	if allowed { out.write_string('<${name}${attrs}>') }
	// Tag.content is normalized inner HTML. Tag.text includes leading text plus
	// descendants; retain just the leading portion before rendering each child.
	mut leading_len := tag.text().len
	for child in tag.children { leading_len -= child.text().len }
	if name != 'br' && leading_len > 0 {
		value := unescape_html(tag.text()[..leading_len])
		out.write_string(escape(value))
		plain.write_string(value)
	}
	for child in tag.children {
		render_rich(child, mut out, mut plain, mut mentions, names, depth + 1)!
	}
	if allowed && name !in ['br', 'hr'] { out.write_string('</${name}>') }
	if name in ['td', 'th'] { plain.write_string('\t') }
	if name in ['br', 'p', 'div', 'li', 'h1', 'h2', 'h3', 'blockquote', 'pre'] {
		plain.write_string('\n')
	}
}
