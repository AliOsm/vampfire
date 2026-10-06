module main

struct User {
pub mut:
	id        int
	name      string
	email     string
	bio       string
	role      string
	status    string
	avatar_id int
}

struct Account {
	name           string
	join_code      string
	restrict_rooms bool
	logo_id        int
}

struct Room {
pub mut:
	id          int
	name        string
	kind        string
	creator_id  int
	involvement string
	unread      int
	last_id     int
	members     []int
}

struct Upload {
pub mut:
	id       int
	name     string
	mime     string
	size     i64
	thumb    string
	width    int
	height   int
	duration f64
}

struct Boost {
	id      int
	user_id int
	name    string
	content string
}

struct ChatMessage {
pub mut:
	id         int
	room_id    int
	user_id    int
	name       string
	avatar_id  int
	client_id  string
	body       string
	plain      string
	reply_id   int
	created_at i64
	updated_at i64
	attachment Upload
	boosts     []Boost
	preview    LinkPreview
}

struct ApiError {
	error string
}

struct Success {
	ok bool = true
}
