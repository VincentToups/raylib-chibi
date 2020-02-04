

/*******************************************************************************************
*
*   raylib [core] example - Basic window
*
*   Welcome to raylib!
*
*   To test examples, just press F6 and execute raylib_compile_execute script
*   Note that compiled executable is placed in the same folder as .c file
*
*   You can find all basic examples on C:\raylib\raylib\examples folder or
*   raylib official webpage: www.raylib.com
*
*   Enjoy using raylib. :)
*
*   This example has been created using raylib 1.0 (www.raylib.com)
*   raylib is licensed under an unmodified zlib/libpng license (View raylib.h for details)
*
*   Copyright (c) 2013-2016 Ramon Santamaria (@raysan5)
*
********************************************************************************************/

#include "raylib.h"
#include "chibi/eval.h"

Image * LoadImagePr(const char * fn){
  Image r;
  Image * im;
  r = LoadImage(fn);
  im = (Image*)malloc(sizeof(Image));
  im->data = r.data;
  im->width = r.width;
  im->height = r.height;
  im->mipmaps = r.mipmaps;
  im->format = r.format;
  return im;
}

void SetWindowIconPr(Image * im){
  SetWindowIcon(*im);
}

void ClearBackgroundPr(Color * clr){
  ClearBackground(*clr);
}

void FreeCamera2DPr(Camera2D * c){
  free(c);
}

void BeginMode2DPr(Camera2D * c){
  BeginMode2D(*c);
}

#include "raylib.c"

int main(int argc, char ** argv)
{
    // Initialization
    //--------------------------------------------------------------------------------------
    char load_str[250];
    char * load_str_format = "(guard (err (#t (display \"Error\") (display \"Error loading main script.\") (newline) (print-exception err) (newline))) (load \"%s\"))";
    const int screenWidth = 800;
    const int screenHeight = 450;
    sexp ctx;

    if(argc<=1){
      sprintf(load_str, load_str_format, "main.scm");
    } else {
      sprintf(load_str, load_str_format, argv[1]);
    }

    ctx = sexp_make_eval_context(NULL, NULL, NULL, 0, 0);
    sexp_load_standard_env(ctx, NULL, SEXP_SEVEN);
    sexp_load_standard_ports(ctx, NULL, stdin, stdout, stderr, 1);
    sexp_init_library(ctx,
                      NULL,
                      3,
                      sexp_context_env(ctx),
                      sexp_version,
                      SEXP_ABI_IDENTIFIER);
    sexp_eval_string(ctx,"(import (scheme base) (chibi))",-1,NULL);
    sexp_eval_string(ctx,"(load \"lib.scm\")",-1,NULL);
    sexp_eval_string(ctx,load_str,-1,NULL);
    sexp_eval_string(ctx,"(guard (err (#t (display \"Error\") (newline) (print-exception err) (newline))) (init))",-1,NULL);
    //sexp_eval_string(ctx,"(init)",-1,NULL);
    

    //InitWindow(screenWidth, screenHeight, "raylib [core] example - basic window");

    //SetTargetFPS(60);               // Set our game to run at 60 frames-per-second
    //--------------------------------------------------------------------------------------

    // Main game loop
    while (!WindowShouldClose())    // Detect window close button or ESC key
    {
        // Update
        //----------------------------------------------------------------------------------
        // TODO: Update your variables here
        //----------------------------------------------------------------------------------

        // Draw
        //----------------------------------------------------------------------------------
      sexp_eval_string(ctx,"(guard (err (#t (display \"Error\") (newline) (print-exception err) (newline))) (draw))",-1,NULL);
        /* BeginDrawing(); */

        /*     ClearBackground(RAYWHITE); */

        /*     DrawText("Congrats! You created your first window!", 190, 200, 20, LIGHTGRAY); */

        /* EndDrawing(); */
        //----------------------------------------------------------------------------------
    }

    // De-Initialization
    //--------------------------------------------------------------------------------------
    CloseWindow();        // Close window and OpenGL context
    //--------------------------------------------------------------------------------------

    sexp_destroy_context(ctx);
    return 0;
}

