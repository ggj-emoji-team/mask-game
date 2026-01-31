extends Node
class_name BubbleSystem

const EMOJI_CORPUS := {
	"LAUGH": {
		"emoji": "😂",
		"lines": [
			"lol",
			"haha",
			"this is fine",
			"nice one",
			"keep going 😂",
			"you’re funny",
			"that was cute",
			"again?",
			"ok ok",
			"lmao"
		]
	},
	"ANGRY": {
		"emoji": "😡",
		"lines": [
			"wrong",
			"no",
			"focus",
			"again",
			"too slow",
			"this is bad",
			"try harder",
			"you failed",
			"not good enough",
			"stop messing up"
		]
	}
}



signal missed_changed(value: int)

@export var bubble_lifetime: float = 3.0  # [UNCHANGED] 单个泡泡存活时间（秒）
@export var max_on_screen: int = 999      # [UNCHANGED] 屏幕最多泡泡（防爆）
@export var bubble_scene: PackedScene     # [UNCHANGED] 要实例化的 Bubble.tscn

# 重要：把 AudioStreamPlayer 拖进来（时间源）
@export var audio_player: AudioStreamPlayer # [UNCHANGED] 用音乐播放时间作为“官方时间”

var missed: int = 0               # [UNCHANGED] 超时未处理泡泡数量
var _queue: Array[Bubble] = []    # [UNCHANGED] FIFO 队列：最老在 index 0

# 你的节奏时间表（秒）
var beatmap_times: Array[float] = [] # [UNCHANGED] 由 GameScene 传入的拍点时间数组
var _beat_idx: int = 0               # [UNCHANGED] 当前生成泡泡的拍点索引

# [CHANGED] 用 get_node_or_null 避免场景路径不对时直接报错崩掉（干扰更小、报错更清楚）
@onready var bubble_queue_ui: VBoxContainer = get_tree().current_scene.get_node_or_null("UI/HUD/BubbleQueue")


func _ready() -> void:
	# [CHANGED] 用一个小函数统一“重置计数+发信号”，避免到处复制 missed=0 + emit
	_reset_counters()


# =========================
# 对外接口（GameScene 会调用）
# =========================

func set_beatmap(times: Array[float]) -> void:
	# [UNCHANGED] 接收谱面时间表
	beatmap_times = times
	_beat_idx = 0


func reset() -> void:
	# [CHANGED] reset 分成“重置计数 / 清队列 / 清 UI / 清谱面进度”四步，逻辑更清晰

	# 1) 清计数（missed=0 并发信号）
	_reset_counters() # [CHANGED]

	# 2) 清逻辑队列（注意：UI 节点会在第 3 步 queue_free）
	_queue.clear() # [UNCHANGED]（你原来就是 clear，这里保留）

	# 3) 清 UI 上的泡泡节点（真正把屏幕上的泡泡删掉）
	if bubble_queue_ui != null:
		for c in bubble_queue_ui.get_children():
			c.queue_free()
	# [CHANGED] 如果 bubble_queue_ui 找不到，这里不崩溃（会在 _can_run() 里给错误提示）

	# 4) 清生成进度
	_beat_idx = 0 # [UNCHANGED]


func consume_oldest_bubble() -> bool:
	# [UNCHANGED] 命中时清最老泡泡（FIFO）
	if _queue.is_empty():
		return false

	var head: Bubble = _queue.pop_front()
	if is_instance_valid(head):
		head.queue_free()
	return true


# =========================
# Godot 主循环：每帧调用
# =========================

func _process(_dt: float) -> void:
	# [CHANGED] _process 变成“调度器”：只负责决定“要不要跑”和“调用哪两个 tick”
	if not _can_run(): # [NEW] 统一判断条件，避免多处写 null/playing/UI 判断
		return

	_tick_spawn()   # [NEW] 生成逻辑入口（目前仍然按 beatmap 生成）
	_tick_expired() # [NEW] 过期逻辑入口（FIFO 检查+missed++）


# =========================
# [NEW] 内部：运行前置条件
# =========================

func _can_run() -> bool:
	# [NEW] 统一判断“系统能不能工作”
	# 目的：把所有必要条件集中到一处，便于调试和验收

	if audio_player == null:
		# 没时间源就没法生成/过期（你当前系统以音乐为时钟）
		return false

	if not audio_player.playing:
		# 音乐没在播，就不推进生成/过期（保持你原行为）
		return false

	if bubble_queue_ui == null:
		# UI 路径不对时，给出明确错误（不直接崩）
		push_error("BubbleSystem: cannot find UI/HUD/BubbleQueue in current scene")
		return false

	return true


# =========================
# [NEW] 内部：统一时间源
# =========================

func _get_now() -> float:
	# [NEW] 系统“官方时间”
	# 这里返回音乐播放到第几秒（节奏游戏最可靠的时间基准）
	# 好处：以后如果换时间源，只改这一行，不用全文件到处改
	return audio_player.get_playback_position()


# =========================
# [NEW] 内部：tick 调度
# =========================

func _tick_spawn() -> void:
	# [NEW] 生成入口：未来如果从“beatmap生成”切到“固定间隔生成”，只改这里
	_spawn_by_beatmap() # [UNCHANGED] 目前仍按 beatmap 生成（不改变你现在行为）


func _tick_expired() -> void:
	# [NEW] 过期入口：把 _check_expired 包一层，_process 更清晰
	_check_expired() # [UNCHANGED]


# =========================
# 生成：按 beatmap 生成泡泡
# =========================

func _spawn_by_beatmap() -> void:
	# [UNCHANGED] 仍是你原来的生成方式（按 beatmap_times）
	if beatmap_times.is_empty():
		return
	if bubble_scene == null:
		push_error("BubbleSystem: bubble_scene not assigned!")
		return

	# [CHANGED] 统一用 _get_now() 获取当前时间，避免重复写 audio_player.get_playback_position()
	var now := _get_now()

	# [UNCHANGED] 用 while 避免卡顿时漏生成
	while _beat_idx < beatmap_times.size() and now >= beatmap_times[_beat_idx]:
		_spawn_bubble(now)
		_beat_idx += 1


# =========================
# [NEW] 生成条件集中判断
# =========================

func _can_spawn() -> bool:
	# [NEW] 把所有“能不能生成”的条件集中到一个函数
	# 目的：_spawn_bubble 更干净；以后调参/加限制也只改这里

	if _queue.size() >= max_on_screen:
		return false
	if bubble_scene == null:
		# 上面 _spawn_by_beatmap 已经检查过，但这里再防御一次更稳
		return false
	if bubble_queue_ui == null:
		return false

	return true


func _spawn_bubble(now: float) -> void:
	# [CHANGED] 先走 _can_spawn()，把条件判断集中管理
	if not _can_spawn():
		return

	# [UNCHANGED] 实例化 Bubble 并设置内容/寿命
	var b := bubble_scene.instantiate() as Bubble

	# --- 随机选情绪 ---
	var emotion_keys := EMOJI_CORPUS.keys()
	var emotion: String = emotion_keys.pick_random()
	var data: Dictionary = EMOJI_CORPUS[emotion]

	# --- 随机选一句话 ---
	var line: String = data["lines"].pick_random()
	var emoji: String = data["emoji"]
	# 最终显示文本
	var text := "%s %s" % [emoji, line]

	b.setup(text, now, bubble_lifetime, emotion)  # ✅ 多传一个 emotion
	bubble_queue_ui.add_child(b)

	# [UNCHANGED] 入队（FIFO）
	_queue.append(b)


func _check_expired() -> void:
	# [UNCHANGED] 队列为空就不用检查
	if _queue.is_empty():
		return

	# [CHANGED] 统一用 _get_now() 获取当前时间
	var now := _get_now()

	# [UNCHANGED] 只从队列头开始检查：头没过期 -> 后面更不可能过期（出生更晚）
	while not _queue.is_empty():
		var head := _queue[0]

		# [UNCHANGED] 如果 head 已经被释放，就把它从队列里丢掉
		if not is_instance_valid(head):
			_queue.pop_front()
			continue

		# [CHANGED] 过期处理：missed++ 统一走 _add_missed()
		if head.is_expired(now):
			head.queue_free()
			_queue.pop_front()
			_add_missed(1) # [NEW] 统一出口：missed += 1 + emit 信号
		else:
			break


# =========================
# [NEW] missed 计数与信号的统一出口
# =========================

	var head: Bubble = _queue.pop_front()
	if is_instance_valid(head):
		head.queue_free()
	return true
	
func peek_oldest_emotion() -> String:
	if _queue.is_empty():
		return ""
	var head: Bubble = _queue[0]
	if not is_instance_valid(head):
		return ""
	return head.emotion
