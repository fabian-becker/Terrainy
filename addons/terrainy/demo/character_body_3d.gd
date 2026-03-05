extends CharacterBody3D

const FORWARD = "w";
const BACKWARD = "s";
const LEFT = "a";
const RIGHT = "d";
const JUMP = "jump";

var speed = 5.0
const JUMP_VELOCITY = 4.5

@onready var camera = $Camera3D

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			speed += 0.5
			speed = max(speed, 0.1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			speed -= 0.5
			speed = max(speed, 0.1)
		return
	if event is InputEventMouseMotion:
		rotate_y(deg_to_rad(-event.relative.x * 0.1))
		camera.rotate_x(deg_to_rad(-event.relative.y * 0.1))
		camera.rotation_degrees.x = clamp(camera.rotation_degrees.x, -90, 90)

func _physics_process(delta: float) -> void:
	# Add the gravity.
	if not is_on_floor():
		velocity += get_gravity() * delta

	# Handle jump.
	if Input.is_action_just_pressed(JUMP) and is_on_floor():
		velocity.y = JUMP_VELOCITY

	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	var input_dir := Input.get_vector(LEFT, RIGHT, FORWARD, BACKWARD)
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)

	move_and_slide()
