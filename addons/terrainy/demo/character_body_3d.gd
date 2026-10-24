extends CharacterBody3D
## Free-fly demo controller.
##
## The body yaws, the [code]Neck[/code] pitches, and [code]WASD[/code] moves the
## body. Movement goes through [method CharacterBody3D.move_and_slide], so the
## terrain chunk collision stops and slides the controller instead of clipping.
## In fly mode [code]Space[/code]/[code]Ctrl[/code] move up/down; in ground mode
## [code]Space[/code] jumps (release early for a shorter hop).
##
## Use the mouse wheel to change the current mode's speed. Press [code]F[/code] to
## toggle between flying and walking on the terrain. Press [code]Esc[/code] to
## release the mouse and click to capture it again.

## Mouse look sensitivity in radians per pixel.
@export var mouse_sensitivity: float = 0.0025

## Current flight speed in metres per second.
@export var speed: float = 30.0

## Multiplier applied to the active mode's speed for each mouse wheel step.
@export var speed_step: float = 1.2

## Lowest speed the mouse wheel can slow either mode down to.
@export var min_speed: float = 0.01

## Maximum look angle up/down in degrees.
@export_range(1.0, 90.0, 1.0) var max_pitch: float = 89.0

@export_group("Ground movement")
## Horizontal walking speed in metres per second.
@export var ground_speed: float = 10.0

@export_group("Jump feel")
## Multiplier applied to project gravity in ground mode. Raise it for a snappier, less floaty jump.
@export var gravity_scale: float = 2.0

## Extra gravity multiplier while falling, so descents feel faster than ascents.
@export var fall_gravity_scale: float = 1.2

## Upward launch speed in metres per second.
@export var jump_velocity: float = 8.5

## Fraction of the upward speed kept when [code]Space[/code] is released early.
@export_range(0.0, 1.0, 0.05) var jump_release_scale: float = 0.7

@export_group("Mode")
## Whether the controller starts in fly mode. Toggle at runtime with [member toggle_flight_key].
@export var start_flying: bool = true

## Key that toggles between flying and walking.
@export var toggle_flight_key: Key = KEY_F

@onready var _neck: Node3D = $Neck

var _yaw: float = 0.0
var _pitch: float = 0.0
var _mouse_captured: bool = false
var _flying: bool = true
var _jump_held: bool = false
var _jumping: bool = false


func _ready() -> void:
	# Preserve the initial view, but move all pitch onto the Neck. The body stays
	# upright so WASD always moves horizontally relative to where the camera looks.
	_yaw = rotation.y
	_pitch = clampf(
		rotation.x + _neck.rotation.x,
		-deg_to_rad(max_pitch),
		deg_to_rad(max_pitch)
	)
	rotation = Vector3(0.0, _yaw, 0.0)
	_neck.rotation = Vector3(_pitch, 0.0, 0.0)
	_set_flying(start_flying)
	_capture_mouse(true)


func _physics_process(delta: float) -> void:
	var input := Vector3.ZERO

	if Input.is_physical_key_pressed(KEY_W):
		input.z -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		input.z += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		input.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		input.x += 1.0

	if _flying:
		_fly(input)
	else:
		_walk(input, delta)


## Free flight: WASD moves horizontally, Space/Ctrl moves vertically, no gravity.
func _fly(input: Vector3) -> void:
	var direction := global_basis * input

	if Input.is_physical_key_pressed(KEY_SPACE):
		direction += Vector3.UP
	if Input.is_physical_key_pressed(KEY_CTRL):
		direction += Vector3.DOWN

	if direction.is_zero_approx():
		velocity = Vector3.ZERO
	else:
		velocity = direction.normalized() * speed
	move_and_slide()


## Ground movement: gravity, jumping and walking on the terrain collision.
func _walk(input: Vector3, delta: float) -> void:
	var jump_pressed := Input.is_physical_key_pressed(KEY_SPACE)

	if is_on_floor():
		_jumping = false
		if jump_pressed and not _jump_held:
			velocity.y = jump_velocity
			_jumping = true
	else:
		var gravity := get_gravity() * gravity_scale
		if velocity.y <= 0.0:
			gravity *= fall_gravity_scale
		velocity += gravity * delta

		# Releasing jump early cuts the ascent for variable jump height.
		if _jumping and velocity.y > 0.0 and not jump_pressed:
			velocity.y *= jump_release_scale
			_jumping = false

	_jump_held = jump_pressed

	var direction := global_basis * input
	direction.y = 0.0
	if direction.is_zero_approx():
		velocity.x = 0.0
		velocity.z = 0.0
	else:
		var horizontal := direction.normalized() * ground_speed
		velocity.x = horizontal.x
		velocity.z = horizontal.z
	move_and_slide()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		_yaw = wrapf(_yaw - event.relative.x * mouse_sensitivity, -PI, PI)
		_pitch = clampf(
			_pitch - event.relative.y * mouse_sensitivity,
			-deg_to_rad(max_pitch),
			deg_to_rad(max_pitch)
		)
		rotation = Vector3(0.0, _yaw, 0.0)
		_neck.rotation = Vector3(_pitch, 0.0, 0.0)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_adjust_speed(speed_step)
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_DOWN:
				_adjust_speed(1.0 / speed_step)
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_LEFT:
				if not _mouse_captured:
					_capture_mouse(true)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_capture_mouse(false)
		elif event.keycode == toggle_flight_key:
			_set_flying(not _flying)


func _set_flying(flying: bool) -> void:
	_flying = flying
	motion_mode = MOTION_MODE_FLOATING if flying else MOTION_MODE_GROUNDED
	_jump_held = Input.is_physical_key_pressed(KEY_SPACE)
	_jumping = false


func _adjust_speed(multiplier: float) -> void:
	if _flying:
		speed = maxf(speed * multiplier, min_speed)
	else:
		ground_speed = maxf(ground_speed * multiplier, min_speed)


func _capture_mouse(captured: bool) -> void:
	_mouse_captured = captured
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE
