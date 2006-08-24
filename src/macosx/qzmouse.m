/*         ______   ___    ___
 *        /\  _  \ /\_ \  /\_ \
 *        \ \ \L\ \\//\ \ \//\ \      __     __   _ __   ___
 *         \ \  __ \ \ \ \  \ \ \   /'__`\ /'_ `\/\`'__\/ __`\
 *          \ \ \/\ \ \_\ \_ \_\ \_/\  __//\ \L\ \ \ \//\ \L\ \
 *           \ \_\ \_\/\____\/\____\ \____\ \____ \ \_\\ \____/
 *            \/_/\/_/\/____/\/____/\/____/\/___L\ \/_/ \/___/
 *                                           /\____/
 *                                           \_/__/
 *
 *      MacOS X mouse driver.
 *
 *      By Angelo Mottola.
 *
 *      See readme.txt for copyright information.
 */


#include "allegro.h"
#include "allegro/internal/aintern.h"
#include "allegro/platform/aintosx.h"

#ifndef ALLEGRO_MACOSX
#error Something is wrong with the makefile
#endif


static int osx_mouse_init(void);
static void osx_mouse_exit(void);
static void osx_mouse_position(int, int);
static void osx_mouse_set_range(int, int, int, int);
static void osx_mouse_get_mickeys(int *, int *);
static void osx_enable_hardware_cursor(AL_CONST int mode);
static int osx_select_system_cursor(AL_CONST int cursor);


MOUSE_DRIVER mouse_macosx = {
   MOUSE_MACOSX,
   empty_string,
   empty_string,
   "MacOS X mouse",
   osx_mouse_init,
   osx_mouse_exit,
   NULL,       // AL_METHOD(void, poll, (void));
   NULL,       // AL_METHOD(void, timer_poll, (void));
   osx_mouse_position,
   osx_mouse_set_range,
   NULL,       // AL_METHOD(void, set_speed, (int xspeed, int yspeed));
   osx_mouse_get_mickeys,
   NULL,       // AL_METHOD(int,  analyse_data, (AL_CONST char *buffer, int size));
   osx_enable_hardware_cursor, 
   osx_select_system_cursor
};


/* global variable */
int osx_mouse_warped = FALSE;
int osx_skip_mouse_move = FALSE;
NSTrackingRectTag osx_mouse_tracking_rect = -1;


static NSCursor *cursor = NULL, *current_cursor = NULL;
static NSCursor *requested_cursor = NULL;
static unsigned char *cursor_data = NULL;
static NSBitmapImageRep *cursor_rep = NULL;
static NSImage *cursor_image = NULL;

static int mouse_minx = 0;
static int mouse_miny = 0;
static int mouse_maxx = 319;
static int mouse_maxy = 199;

static int mymickey_x = 0;
static int mymickey_y = 0;

static char driver_desc[256];



/* osx_mouse_handler:
 *  Mouse "interrupt" handler for mickey-mode driver.
 */
void osx_mouse_handler(int ax, int ay, int x, int y, int z, int buttons)
{
   if (!_mouse_on)
      mymickey_x = mymickey_y = 0;

   if ((!_mouse_installed) || (!_mouse_on) || (osx_gfx_mode == OSX_GFX_NONE))
      return;

   if (osx_cursor != current_cursor) {
      if (osx_window) {
         NSView* vw = [osx_window contentView];
         [osx_window invalidateCursorRectsForView: vw];
      }
      else {
         [osx_cursor set];
      }
      current_cursor = osx_cursor;
   }

   if (osx_mouse_warped) {
      osx_mouse_warped = FALSE;
      return;
   }
   
   _mouse_b = buttons;
   
   mymickey_x += x;
   mymickey_y += y;
   _mouse_x = ax;
   _mouse_y = ay;
   _mouse_z += z;
   
   _mouse_x = MID(mouse_minx, _mouse_x, mouse_maxx);
   _mouse_y = MID(mouse_miny, _mouse_y, mouse_maxy);

   _handle_mouse_input();
}



/* osx_mouse_init:
 *  Initializes the mickey-mode driver.
 */
static int osx_mouse_init(void)
{
   HID_DEVICE_COLLECTION devices={0,0,NULL};
   int i, j;
   int buttons, max_buttons = -1;
   HID_DEVICE* device;
   
   if (floor(NSAppKitVersionNumber) <= NSAppKitVersionNumber10_1) {
      /* On 10.1.x mice and keyboards aren't available from the HID Manager,
       * so we can't autodetect. We assume an 1-button mouse to always be
       * present.
       */
      max_buttons = 1;
   }
   else {
      osx_hid_scan(HID_MOUSE, &devices);
      for (i = 0; i < devices.count; i++) {
         device=&devices.devices[i];
         buttons = 0;
         for (j = 0; j < device->num_elements; j++) {
            if (device->element[j].type == HID_ELEMENT_BUTTON)
	       buttons++;
         }
         if (buttons > max_buttons) {
            max_buttons = buttons;
	    _al_sane_strncpy(driver_desc, "", sizeof(driver_desc));
            if (device->manufacturer) {
	       strncat(driver_desc, device->manufacturer, sizeof(driver_desc)-1);
	       strncat(driver_desc, " ", sizeof(driver_desc)-1);
	    }
	    if (device->product)
	       strncat(driver_desc, device->product, sizeof(driver_desc)-1);
	    mouse_macosx.desc = driver_desc;
	 }
      }
      osx_hid_free(&devices);
   }
   
   _al_mutex_lock(&osx_event_mutex);
   osx_emulate_mouse_buttons = (max_buttons == 1) ? TRUE : FALSE;
   _al_mutex_unlock(&osx_event_mutex);

   return max_buttons;
}



/* osx_mouse_exit:
 *  Shuts down the mickey-mode driver.
 */
static void osx_mouse_exit(void)
{
   osx_cursor = osx_blank_cursor;
   if (cursor)
      [cursor release];
   if (cursor_image)
      [cursor_image release];
   if (cursor_rep)
      [cursor_rep release];
   if (cursor_data)
      free(cursor_data);
   cursor = NULL;
   cursor_image = NULL;
   cursor_rep = NULL;
   cursor_data = NULL;
}



/* osx_mouse_position:
 *  Sets the position of the mickey-mode mouse.
 */
static void osx_mouse_position(int x, int y)
{
   CGPoint point;
   NSRect frame;
   int screen_height;
   
   _al_mutex_lock(&osx_event_mutex);
   
   _mouse_x = point.x = x;
   _mouse_y = point.y = y;
   
   if (osx_window) {
      CFNumberGetValue(CFDictionaryGetValue(CGDisplayCurrentMode(kCGDirectMainDisplay), kCGDisplayHeight), kCFNumberSInt32Type, &screen_height);
      frame = [osx_window frame];
      point.x += frame.origin.x;
      point.y += (screen_height - (frame.origin.y + gfx_driver->h));
   }
   
   CGDisplayMoveCursorToPoint(kCGDirectMainDisplay, point);
   
   mymickey_x = mymickey_y = 0;
   osx_mouse_warped = TRUE;

   _al_mutex_unlock(&osx_event_mutex);
}



/* osx_mouse_set_range:
 *  Sets the range of the mickey-mode mouse.
 */
static void osx_mouse_set_range(int x1, int y1, int x2, int y2)
{
   mouse_minx = x1;
   mouse_miny = y1;
   mouse_maxx = x2;
   mouse_maxy = y2;
   
   osx_mouse_position(MID(mouse_minx, _mouse_x, mouse_maxx), MID(mouse_miny, _mouse_y, mouse_maxy));
}



/* osx_mouse_get_mickeys:
 *  Reads the mickey-mode count.
 */
static void osx_mouse_get_mickeys(int *mickeyx, int *mickeyy)
{
   _al_mutex_lock(&osx_event_mutex);
   
   *mickeyx = mymickey_x;
   *mickeyy = mymickey_y;
   mymickey_x = mymickey_y = 0;

   _al_mutex_unlock(&osx_event_mutex);
}



/* osx_mouse_set_sprite:
 *  Sets the hardware cursor sprite.
 */
int osx_mouse_set_sprite(BITMAP *sprite, int x, int y)
{
   int ix, iy;
   int r = 0, g = 0, b = 0, a = 0, col;
   unsigned int *d;
   BITMAP *temp = NULL;
#define GET_PIXEL_DATA(depth, getpix)                                \
               case depth:                                           \
                  for(iy=0; iy<sprite->h; iy++) {                    \
                     for(ix=0; ix<sprite->w;  ix++) {                \
                        col = getpix(sprite, ix, iy);                \
                        if (col == (MASK_COLOR_ ## depth)) {         \
                           r = g = b = a = 0;                        \
                        }                                            \
                        else {                                       \
                           r = getr ## depth(col);                   \
                           g = getg ## depth(col);                   \
                           b = getb ## depth(col);                   \
                           a = 255;                                  \
                        }                                            \
			*d++ = (r<<24)|(g<<16)|(b<<8)|(a);           \
                     }                                               \
                  }

   if (!sprite)
      return -1;

   if (floor(NSAppKitVersionNumber) <= NSAppKitVersionNumber10_2) {
      /* Before MacOS X 10.3, NSCursor can handle only 16x16 cursor sprites */
      if ((sprite->w != 16) || (sprite->h != 16)) {
         if ((sprite->w <= 16) && (sprite->h <= 16)) {
	    /* Enlarge sprite to suit requirement */
	    temp = create_bitmap_ex(bitmap_color_depth(sprite), 16, 16);
	    clear_to_color(temp, bitmap_mask_color(temp));
	    blit(sprite, temp, 0, 0, 0, 0, sprite->w, sprite->h);
	    sprite = temp;
	 }
	 else
	    return -1;
      }
   }
   
   if (cursor)
      [cursor release];
   if (cursor_image)
      [cursor_image release];
   if (cursor_rep)
      [cursor_rep release];
   if (cursor_data)
      free(cursor_data);

   cursor_data = malloc(sprite->w * sprite->h * 4);
   d = (unsigned int *)cursor_data;
   
   switch(bitmap_color_depth(sprite)) {
      GET_PIXEL_DATA(8, _getpixel)
         break;

      GET_PIXEL_DATA(15, _getpixel15)
         break;

      GET_PIXEL_DATA(16, _getpixel16)
         break;

      GET_PIXEL_DATA(24, _getpixel24)
         break;

      GET_PIXEL_DATA(32, _getpixel32)
         break;
   }
   
   cursor_rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes: &cursor_data
                                          pixelsWide: sprite->w
                                          pixelsHigh: sprite->h
                                          bitsPerSample: 8
                                          samplesPerPixel: 4
                                          hasAlpha: YES
                                          isPlanar: NO
                                          colorSpaceName: NSDeviceRGBColorSpace
                                          bytesPerRow: sprite->w * 4
                                          bitsPerPixel: 32];
   cursor_image = [[NSImage alloc] initWithSize: NSMakeSize(sprite->w, sprite->h)];
   [cursor_image addRepresentation: cursor_rep];
   cursor = [[NSCursor alloc] initWithImage: cursor_image
                              hotSpot: NSMakePoint(x, y)];
   _al_mutex_lock(&osx_event_mutex);
   osx_cursor = requested_cursor = cursor;
   _al_mutex_unlock(&osx_event_mutex);
   if (temp)
      destroy_bitmap(temp);

#undef GET_PIXEL_DATA
   return 0;
}



/* osx_mouse_show:
 *  Show the hardware cursor.
 */
int osx_mouse_show(BITMAP *bmp, int x, int y)
{
   /* Only draw on screen */
   if (!is_same_bitmap(bmp, screen))
      return -1;

   if (!requested_cursor)
      return -1;

   _al_mutex_lock(&osx_event_mutex);
   osx_cursor = requested_cursor;
   _al_mutex_unlock(&osx_event_mutex);

   return 0;
}



/* osx_mouse_hide:
 *  Hide the hardware cursor.
 */
void osx_mouse_hide(void)
{
   _al_mutex_lock(&osx_event_mutex);
   osx_cursor = osx_blank_cursor;
   _al_mutex_unlock(&osx_event_mutex);
}



/* osx_mouse_move:
 *  Get mouse move notification. Not that we need it...
 */
void osx_mouse_move(int x, int y)
{
}



/* osx_enable_hardware_cursor:
 *  Enable hardware cursor - on OSX it's always enabled.
 */
void osx_enable_hardware_cursor(AL_CONST int mode) 
{
   (void)mode;
}



/* osx_select_system_cursor:
 *  Select a system cursor - on this platform, only the I-beam and the Arrow
 *  are available as system cursors.
 */
static int osx_select_system_cursor(AL_CONST int cursor)
{
   switch (cursor) {
   case MOUSE_CURSOR_ARROW:
      requested_cursor = [NSCursor arrowCursor];
      break;
   case MOUSE_CURSOR_EDIT:
      requested_cursor = [NSCursor IBeamCursor];
      break;
   default:
      return 0;
   }
   _al_mutex_lock(&osx_event_mutex);
   osx_cursor = requested_cursor;
   _al_mutex_unlock(&osx_event_mutex);
   return cursor;
}



/* Local variables:       */
/* c-basic-offset: 3      */
/* indent-tabs-mode: nil  */
/* End:                   */
