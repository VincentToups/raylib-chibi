;; int main(void)
;; {
;;     // Initialization
;;     //--------------------------------------------------------------------------------------
;;     const int screenWidth = 800;
;;     const int screenHeight = 450;

;;     InitWindow(screenWidth, screenHeight, "raylib [core] example - 3d camera mode");

;;     // Define the camera to look into our 3d world
;;     Camera3D camera = { 0 };
;;     camera.position = (Vector3){ 0.0f, 10.0f, 10.0f };  // Camera position
;;     camera.target = (Vector3){ 0.0f, 0.0f, 0.0f };      // Camera looking at point
;;     camera.up = (Vector3){ 0.0f, 1.0f, 0.0f };          // Camera up vector (rotation towards target)
;;     camera.fovy = 45.0f;                                // Camera field-of-view Y
;;     camera.type = CAMERA_PERSPECTIVE;                   // Camera mode type

;;     Vector3 cubePosition = { 0.0f, 0.0f, 0.0f };

;;     SetTargetFPS(60);               // Set our game to run at 60 frames-per-second
;;     //--------------------------------------------------------------------------------------

;;     // Main game loop
;;     while (!WindowShouldClose())    // Detect window close button or ESC key
;;     {
;;         // Update
;;         //----------------------------------------------------------------------------------
;;         // TODO: Update your variables here
;;         //----------------------------------------------------------------------------------

;;         // Draw
;;         //----------------------------------------------------------------------------------
;;         BeginDrawing();

;;             ClearBackground(RAYWHITE);

;;             BeginMode3D(camera);

;;                 DrawCube(cubePosition, 2.0f, 2.0f, 2.0f, RED);
;;                 DrawCubeWires(cubePosition, 2.0f, 2.0f, 2.0f, MAROON);

;;                 DrawGrid(10, 1.0f);

;;             EndMode3D();

;;             DrawText("Welcome to the third dimension!", 10, 40, 20, DARKGRAY);

;;             DrawFPS(10, 10);

;;         EndDrawing();
;;         //----------------------------------------------------------------------------------
;;     }

;;     // De-Initialization
;;     //--------------------------------------------------------------------------------------
;;     CloseWindow();        // Close window and OpenGL context
;;     //--------------------------------------------------------------------------------------

;;     return 0;
;; }

(define camera #f)
(define cube-position #f)

(define (init)
  (init-window 800 600 "Hello 3d")
  (display-nl "About to init camera")
  (set! camera (make-camera-3d
                (make-vector-3 0.0 10.0 10.0)
                (make-vector-3 0.0 0.0 0.0)
                (make-vector-3 0.0 1.0 0.0)
                45.0
                0))
  (display-nl "Did it")
  (set! cube-position (make-vector-3 0.0 0.0 0.0))
  (set-target-fps 60))

(define (draw)
  (begin-drawing)
  (clear-background (color 255 255 255 255))
  (begin-mode-3d camera)
  (draw-cube cube-position 2.0 2.0 2.0 (color 255 0 0  255))
  (draw-grid 10 1.0)
  (end-mode-3d)
  (draw-text "Hello 3d" 190 200 20 (color 192 192 192 255))
  (end-drawing)
  )
