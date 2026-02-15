#import "tbx/model_loading";
#import "tbx/geometry";
#import "tbx/opengl";
#import "tbx/camera";
#import "tbx/movement";
#import "tbx/collision";
#import "tbx/math";
#import "tbx/engine";
#import "tbx/physics";

#import "Basic";
#import "GL";
#import "File";
#import "Random";
#import "Math";
#import "Window_Creation";
#import "GetRect";

Simp :: #import "Simp";
using,except(Shader) Simp;

Input :: #import "Input";

convert_obj_to_indexed_meshes :: (obj_data: *Obj_Data) -> [..] Indexed_Mesh {
    meshes: [..] Indexed_Mesh;
    
    for *obj_object : obj_data.all_objects {
        mesh: Indexed_Mesh;
        current_index: u32 = 0;
        
        for *face : obj_object.faces {
            if face.face_vertices.count < 3 continue;

            // now there are at least 3 vertices on this face.
            
            first_index := current_index;
            
            for *fv : face.face_vertices {
                array_add(*mesh.positions, obj_data.all_positions[fv.position_index]);
                
                // handle optional texture coordinates
                if fv.texture_coordinate_index >= 0 {
                    array_add(*mesh.texture_coordinates, obj_data.all_texture_coordinates[fv.texture_coordinate_index]);
                } else {
                    array_add(*mesh.texture_coordinates, .{0, 0});
                }
                
                // Handle optional normals
                if fv.normal_index >= 0 {
                    array_add(*mesh.normals, obj_data.all_normals[fv.normal_index]);
                } else {
                    array_add(*mesh.normals, .{0, 1, 0});  // default up normal
                }

                // this is temporary
                r1 := random_get_zero_to_one();
                r2 := random_get_zero_to_one();
                r3 := random_get_zero_to_one();
                random_color := Vector3.{r1, r2, r3};

                array_add(*mesh.rgb_colors, random_color);

                current_index += 1;
            }
            
            // fan triangulation (in case there are more than 3 verts on a face)
            for i : 1..face.face_vertices.count-2 {
                array_add(*mesh.indices, first_index);
                array_add(*mesh.indices, first_index + cast(u32) i);
                array_add(*mesh.indices, first_index + cast(u32) i + 1);
            }
        }
        
        array_add(*meshes, mesh);
    }
    
    return meshes;
}

Renderable :: struct {
    indexed_mesh : Indexed_Mesh;
    local_to_world_index : u32;
    render_object_index : u32;
};

Character :: struct {
    using #as cg : Collision_Geometry;
    using r : Renderable;
}

do_collision_simulation :: (windowed_program_3d : *Windowed_Program_3D, delta_time : float, velocity : *Vector3, on_ground : *bool,  character : *Character, map : Collision_Geometries, renderables: [] Renderable, movement_mode: Movement_Mode) {
    // this moves the character to the camera's position
    // windowed_program_3d.per_object_transform_renderer.local_to_world_matrices[character_local_to_world_index] = make_translation_matrix4(windowed_program_3d.camera.position);

    // this is the character.
    // queue_render(*windowed_program_3d.per_object_transform_renderer, character.render_object_index);
    for renderables queue_render(*windowed_program_3d.per_object_transform_renderer, it.render_object_index);

    row_major := GL_TRUE;
    num_matrices_we_are_updating :u32 = 1;

    if (movement_mode == .GOD) {
        gmi := God_Mode_Input.{
            is_key_down (xx #char "E"),
            is_key_down (xx #char "Q"),
            is_key_down (xx #char "W"),
            is_key_down (xx #char "S"),
            is_key_down (xx #char "D"),
            is_key_down (xx #char "A"),
            is_key_down (xx #char " "),
            is_key_down (Input.Key_Code.SHIFT),
        }; 

        velocity.* = get_new_god_mode_velocity(velocity.*, get_forward(*windowed_program_3d.camera), gmi, delta_time);
    } 

    old_velocity := velocity.*;
    new_velocity : Vector3;
    if (movement_mode == .FPS) {
        fpmi := First_Person_Movement_Input.{
            is_key_down (xx #char "W"),
            is_key_down (xx #char "S"),
            is_key_down (xx #char "D"),
            is_key_down (xx #char "A"),
            is_key_down (xx #char " "),
        }; 

        ground_state : Ground_State = ifx on_ground.* then .ON_GROUND else .IN_AIR;

        new_velocity = get_new_first_person_velocity(velocity.*, fpmi, get_forward(*windowed_program_3d.camera), delta_time, ground_state, Movement_Params.{acceleration_mpss = 20});
    }

    ellipsoid_radius := v3(0.4, 1.75 / 2, 0.4);  
    displacement := displacement_from_kinematic_update(old_velocity, new_velocity, delta_time);
    resolve_collisions_against_body_ellipsoid(map, ellipsoid_radius, *windowed_program_3d.camera.position, *displacement, on_ground);

    velocity.* = new_velocity;

    glUseProgram(windowed_program_3d.per_object_transform_renderer.shader_program_gl_handle);

    Simp.update_window (windowed_program_3d.window);
    Simp.clear_render_target(.15, .08, .08, 1);

    glDepthMask (GL_TRUE);
    glEnable (GL_DEPTH_TEST);

    glClear (GL_DEPTH_BUFFER_BIT);

    render(*windowed_program_3d.per_object_transform_renderer);

    context.simp.current_shader = null;
    render_tick_stats(windowed_program_3d);
    render_camera_stats(windowed_program_3d);

    swap_buffers(windowed_program_3d.window, false);
}

run_mesh_based_collision_program :: () {
    windowed_program_3d : Windowed_Program_3D;
    windowed_program_3d.movement_mode = .MANUAL;
    windowed_program_3d.camera_mode = .FIRST_PERSON;
    windowed_program_3d.window_width = 1000;
    windowed_program_3d.window_height = 1000;
    windowed_program_3d.window_name = "mwe_collision";

    windowed_program_3d.camera.offset = Y3 * 1.75 * 0.25;

    init(*windowed_program_3d);

    obj_data := load_obj("data/lair.obj");
    // obj_data := load_obj("data/gravity_test.obj");
    // just assuming that meshes live till the end of the program for now.
    meshes := convert_obj_to_indexed_meshes(*obj_data);

    map : Collision_Geometries;

    movement_mode := Movement_Mode.FPS;

    for meshes {
        cg : Collision_Geometry;
        cg.indexed_triangle_positions.indices = it.indices;
        cg.indexed_triangle_positions.positions = it.positions;


        cg.aabb = create_aabb_from_positions(cg.indexed_triangle_positions.positions);

        array_add(*map.indexed_triangle_positions,cg.indexed_triangle_positions);
        array_add(*map.aabbs,cg.aabb);
    }

    character : Character;
    character.indexed_triangle_positions = create_box(ZERO3, 0.4, 1.75, 0.4); 
    character.aabb = create_aabb_from_positions(character.indexed_triangle_positions.positions);
    character.indexed_mesh.indices = character.indexed_triangle_positions.indices;
    character.indexed_mesh.positions = character.indexed_triangle_positions.positions;

    for 1..character.indexed_mesh.positions.count array_add(*character.indexed_mesh.rgb_colors, .{0, .5, .5});

    character_local_to_world_index: u32;
    character.render_object_index, character_local_to_world_index = buffer_object(*windowed_program_3d.per_object_transform_renderer, character.indexed_mesh.indices, character.indexed_mesh.positions, character.indexed_mesh.rgb_colors);

    windowed_program_3d.camera.position = Y3 * 100;
    velocity : Vector3;
    on_ground : bool;

    renderables : [..] Renderable;
    
    count := 10;
    for meshes {
        renderable: Renderable;
        renderable.indexed_mesh = it;
        
        renderable.render_object_index, renderable.local_to_world_index = buffer_object(*windowed_program_3d.per_object_transform_renderer, renderable.indexed_mesh.indices, renderable.indexed_mesh.positions, renderable.indexed_mesh.rgb_colors);

        array_add(*renderables, renderable);

        count += 1;
    }

    quit := false;
    while !windowed_program_3d.end_program {

        mark_frame_start(*windowed_program_3d);

        if is_key_just_pressed(xx #char "M")
            toggle_menu(*windowed_program_3d);

        per_frame_update(*windowed_program_3d);

        if (windowed_program_3d.current_menu == .NONE) {
            do_collision_simulation(*windowed_program_3d, windowed_program_3d.delta_time, *velocity, *on_ground, *character, map, renderables, movement_mode);
            context.simp.current_shader = null; 
        } else {
            context.simp.current_shader = null;
            clear_render_target(.35, .35, .35, 1);
            render_menus(*windowed_program_3d.wp);
            // swap_buffers(windowed_program_3d.window, windowed_program_3d.vsync);
            swap_buffers(windowed_program_3d.window, false);
        }

        sleep_to_maintain_max_fps(*windowed_program_3d);
        mark_frame_end(*windowed_program_3d);
    }
}

run_brush_based_collision_program :: () {
    windowed_program_3d : Windowed_Program_3D;
    windowed_program_3d.movement_mode = .MANUAL;
    windowed_program_3d.camera_mode = .THIRD_PERSON;
    windowed_program_3d.window_width = 1280;
    windowed_program_3d.window_height = 720;
    windowed_program_3d.window_name = "mwe_collision";

    init(*windowed_program_3d);

    // Load and parse the .map file instead of .obj
    map_content, success_read := read_entire_file("data/lair.map");
    if !success_read {
        log_error("Failed to read map file");
        return;
    }
    
    map, success := parse_map(map_content, .Y_UP, 0.05);
    if !success {
        log_error("Failed to parse map file");
        return;
    }

    // After parsing, print out the brush planes to verify normals
    for * entity : map.entities {
        for brush_idx : 0..entity.brushes.count-1 {
            brush := *entity.brushes[brush_idx];
            print("Brush %:\n", brush_idx);
            for plane_idx : 0..brush.planes.count-1 {
                plane := brush.planes[plane_idx];
                print("  Plane %: normal=(%, %, %) d=%\n", 
                      plane_idx, plane.normal.x, plane.normal.y, plane.normal.z, plane.d);
            }
        }
    }

    // Convert map brushes to renderable mesh
    map_mesh := map_to_mesh_deduplicated(*map);

    movement_mode := Movement_Mode.GOD;

    // Create player using the new Player struct
    player : Player;
    player.position = .{ 0, 100, 0 };  // Start position (Y is up now, was {0, 0, 100})
    player.velocity = .{ 0, 0, 0 };
    player.radius = 0.2;   // Half of the old 0.4 width
    player.height = 1.75;

    // Create a visual representation for the player (cylinder approximated as box for now)
    player_mesh := create_box(ZERO3, player.radius * 2, player.height, player.radius * 2);
    
    player_indexed_mesh : Indexed_Mesh;
    player_indexed_mesh.indices = player_mesh.indices;
    player_indexed_mesh.positions = player_mesh.positions;
    
    player_local_to_world_indices : [..] u32;
    for 1..player_indexed_mesh.positions.count {
        array_add(*player_indexed_mesh.rgb_colors, .{random_get_zero_to_one(), random_get_zero_to_one(), random_get_zero_to_one()});
    }

    // player_render_object_index := buffer_object(
    //     *windowed_program_3d.per_object_transform_renderer, 
    //     player_indexed_mesh.indices, 
    //     player_local_to_world_indices, 
    //     player_indexed_mesh.positions, 
    //     player_indexed_mesh.rgb_colors
    // );

    windowed_program_3d.camera.position = Y3 * 30;

    // Create renderable for the map geometry
    renderables : [..] Renderable;
    
    renderable: Renderable;
    renderable.indexed_mesh.indices = map_mesh.indices;
    renderable.indexed_mesh.positions = map_mesh.positions;
    
    // Generate colors for the map mesh
    for 1..renderable.indexed_mesh.positions.count {
        array_add(*renderable.indexed_mesh.rgb_colors, .{random_get_zero_to_one(), random_get_zero_to_one(), random_get_zero_to_one()});  // Gray color
    }
    
    renderable.render_object_index, renderable.local_to_world_index = buffer_object(
        *windowed_program_3d.per_object_transform_renderer, 
        renderable.indexed_mesh.indices, 
        renderable.indexed_mesh.positions, 
        renderable.indexed_mesh.rgb_colors
    );
    
    array_add(*renderables, renderable);

    quit := false;
    while !windowed_program_3d.end_program {

        mark_frame_start(*windowed_program_3d);

        Input.update_window_events();
        for Input.events_this_frame {
            if it.type == .QUIT then quit = true;

            getrect_handle_event(it);

            if it.type == {
              case .KEYBOARD;
                if it.key_pressed && it.key_code == .ESCAPE {
                    quit = true;
                }
            }
        }

        if is_key_just_pressed(xx #char "M")
            toggle_menu(*windowed_program_3d);
    
        for Input.get_window_resizes() {
            Simp.update_window(it.window);  
            if it.window == windowed_program_3d.window {
                should_reinit := (it.width != windowed_program_3d.window_width) || (it.height != windowed_program_3d.window_height);

                windowed_program_3d.window_width  = it.width;
                windowed_program_3d.window_height = it.height;
            }
        }

        per_frame_update(*windowed_program_3d);

        if (windowed_program_3d.current_menu == .NONE) {


            // Handle player input for movement - God Mode (free fly)
            gmi := God_Mode_Input.{
                is_key_down (xx #char "E"),
                is_key_down (xx #char "Q"),
                is_key_down (xx #char "W"),
                is_key_down (xx #char "S"),
                is_key_down (xx #char "D"),
                is_key_down (xx #char "A"),
                is_key_down (xx #char " "),
                is_key_down (Input.Key_Code.SHIFT),
            }; 

            player.velocity = get_new_god_mode_velocity(player.velocity, get_forward(*windowed_program_3d.camera), gmi, windowed_program_3d.delta_time);
            
            // Update position directly (no gravity, no collision)
            player.position += player.velocity * windowed_program_3d.delta_time;

            if !is_key_down( xx #char "C") {
                update_player(*player, *map, windowed_program_3d.delta_time);
            }
            
            // Update player transform for rendering
            player_transform := make_translation_matrix4(player.position);

            // Offset down by half height since the box is centered
            // player_transform._24 -= player.height / 2;
            
            // this moves the character to the camera's position
            // windowed_program_3d.per_object_transform_renderer.local_to_world_matrices[0] = make_translation_matrix4(player.position);

            // queue_render(*windowed_program_3d.per_object_transform_renderer, player_render_object_index);
            
            
            // Update camera to follow player (Y is up now)
            windowed_program_3d.camera.position = player.position;
            
            // this is just the map dumb!
            for renderables queue_render(*windowed_program_3d.per_object_transform_renderer, it.render_object_index);
            
            clear_render_target(.35, .35, .35, 1);  // Or whatever background color you want

            glDepthMask (GL_TRUE);
            glEnable (GL_DEPTH_TEST);

            glClear (GL_DEPTH_BUFFER_BIT);

            render(*windowed_program_3d.per_object_transform_renderer);

            context.simp.current_shader = null;
            render_tick_stats(windowed_program_3d);

            // swap_buffers(windowed_program_3d.window, windowed_program_3d.vsync);
            swap_buffers(windowed_program_3d.window, false);


        } else {
            context.simp.current_shader = null;
            clear_render_target(.35, .35, .35, 1);
            render_menus(*windowed_program_3d.wp);
            swap_buffers(windowed_program_3d.window, false);
        }

        sleep_to_maintain_max_fps(*windowed_program_3d);
        mark_frame_end(*windowed_program_3d);
    }
}

main :: () {
    run_mesh_based_collision_program();
    // run_brush_based_collision_program();
    // test();


}

test_grav_iterative :: () {

    
    fpmi := First_Person_Movement_Input.{};
    ground_state := Ground_State.IN_AIR;

    position, velocity : Vector3;

    delta_time := 1.0 / 60;

    for 1..60 {
        new_velocity := get_new_first_person_velocity(velocity, fpmi, Z3, delta_time, ground_state, Movement_Params.{acceleration_mpss = 20});
        empirical_acceleration := (new_velocity - velocity) / delta_time;
        displacement := velocity * delta_time + 0.5 * (empirical_acceleration) * pow(delta_time, 2);

        position += displacement;

        velocity = new_velocity;

        log("it: %, vel: %, pos: %", it, velocity, position);
    }
}










