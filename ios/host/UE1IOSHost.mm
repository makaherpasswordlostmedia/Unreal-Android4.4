// UE1IOSHost.mm - iOS host glue for Unreal (UE1 v200) armv7, iOS 7+.
//
//  * Documents path + file log
//  * First-run config fix-up (Unreal.ini / User.ini): GLES2 + OpenAL + SDL drivers
//  * On-screen touch controls: floating left move-stick + buttons feed the normal
//    SDL_CONTROLLER* event path of NSDLViewport; dragging anywhere on the right half
//    is relative touch-look (mouse-like) via UE1IOSPushLook. Hidden in menus (SDL's own
//    touch->mouse emulation drives the menus) and when an MFi pad is connected.
//  * Audio suspend/resume on app background (SDL event watch).
//
// Only APIs available on iOS 7.0 are used (no containsString:, UIAlertController...).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#include <SDL2/SDL.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
extern "C" void UE1IOSLog( const char* Msg ); // ios_diag.mm

extern "C" void UE1AndroidSetAudioSuspended( int Suspended ); // NOpenALDrv (name kept from the Android port)
extern "C" void UE1IOSPushLook( float DX, float DY );                   // NSDLViewport: touch-look deltas (finger points)

// User-tunable (Unreal.ini [IOSTouch]).
static float GLookSens = 1.4f;   // mouse counts per finger point; the in-game mouse sensitivity scales it further
static float GRenderScale = 0.6f; // fraction of native resolution the GL surface renders at
static float GCtlScale = 1.0f;   // overall size of the on-screen buttons

// ---------------------------------------------------------------------------
// Paths / logging
// ---------------------------------------------------------------------------
extern "C" const char* UE1IOSDocumentsDir( void )
{
	static char Buf[1024];
	if( !Buf[0] )
	{
		NSArray* Dirs = NSSearchPathForDirectoriesInDomains( NSDocumentDirectory, NSUserDomainMask, YES );
		if( [Dirs count] )
			strlcpy( Buf, [[Dirs objectAtIndex:0] fileSystemRepresentation], sizeof(Buf) );
	}
	return Buf;
}

static void UE1IOSLog_Unused( const char* Msg )
{
	static pthread_mutex_t Lock = PTHREAD_MUTEX_INITIALIZER;
	if( !Msg ) return;
	NSLog( @"[Unreal] %s", Msg );
	pthread_mutex_lock( &Lock );
	char Path[1100];
	snprintf( Path, sizeof(Path), "%s/unreal_ios.log", UE1IOSDocumentsDir() );
	if( FILE* F = fopen( Path, "a" ) )
	{
		fprintf( F, "%s\n", Msg );
		fclose( F );
	}
	pthread_mutex_unlock( &Lock );
}

// ---------------------------------------------------------------------------
// Minimal INI editing (CRLF-preserving, case-insensitive)
// ---------------------------------------------------------------------------
static NSMutableArray* IniLines( NSString* Text, BOOL* OutCRLF )
{
	*OutCRLF = [Text rangeOfString:@"\r\n"].location != NSNotFound;
	NSString* N = [Text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
	N = [N stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
	return [[N componentsSeparatedByString:@"\n"] mutableCopy];
}

static NSString* Trim( NSString* S )
{
	return [S stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// Sets Key=Value inside [Section]. If Overwrite is NO an existing key is left alone.
static void IniSet( NSMutableArray* Lines, NSString* Section, NSString* Key, NSString* Value, BOOL Overwrite )
{
	NSString* Header = [NSString stringWithFormat:@"[%@]", Section];
	NSInteger SecStart = -1;
	for( NSUInteger i = 0; i < [Lines count]; i++ )
		if( [Trim( [Lines objectAtIndex:i] ) caseInsensitiveCompare:Header] == NSOrderedSame ) { SecStart = (NSInteger)i; break; }

	NSString* NewLine = [NSString stringWithFormat:@"%@=%@", Key, Value];
	if( SecStart < 0 )
	{
		if( [Lines count] && [Trim( [Lines lastObject] ) length] ) [Lines addObject:@""];
		[Lines addObject:Header];
		[Lines addObject:NewLine];
		return;
	}
	NSInteger LastContent = SecStart;
	for( NSUInteger i = (NSUInteger)SecStart + 1; i < [Lines count]; i++ )
	{
		NSString* T = Trim( [Lines objectAtIndex:i] );
		if( [T hasPrefix:@"["] ) break;
		if( [T length] && ![T hasPrefix:@";"] )
		{
			LastContent = (NSInteger)i;
			NSRange Eq = [T rangeOfString:@"="];
			if( Eq.location != NSNotFound && [Trim( [T substringToIndex:Eq.location] ) caseInsensitiveCompare:Key] == NSOrderedSame )
			{
				if( Overwrite ) [Lines replaceObjectAtIndex:i withObject:NewLine];
				return;
			}
		}
	}
	[Lines insertObject:NewLine atIndex:(NSUInteger)LastContent + 1];
}

static void IniEdit( NSString* Path, void (^Edit)(NSMutableArray* L) )
{
	NSString* Text = [NSString stringWithContentsOfFile:Path encoding:NSUTF8StringEncoding error:nil];
	if( !Text ) Text = [NSString stringWithContentsOfFile:Path encoding:NSISOLatin1StringEncoding error:nil];
	if( !Text ) Text = @"";
	BOOL CRLF = NO;
	NSMutableArray* L = IniLines( Text, &CRLF );
	NSString* Before = [L componentsJoinedByString:@"\n"];
	Edit( L );
	NSString* After = [L componentsJoinedByString:@"\n"];
	if( [After isEqualToString:Before] && [Text length] ) return; // nothing changed
	if( CRLF ) After = [After stringByReplacingOccurrencesOfString:@"\n" withString:@"\r\n"];
	[After writeToFile:Path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

extern "C" void UE1IOSPrepareConfig( const char* SystemDir )
{
	@autoreleasepool
	{
		NSString* Dir = [NSString stringWithUTF8String:SystemDir];
		NSString* UnrealIni = [Dir stringByAppendingPathComponent:@"Unreal.ini"];
		NSString* UserIni   = [Dir stringByAppendingPathComponent:@"User.ini"];

		// Keep the pristine retail ini once.
		NSFileManager* FM = [NSFileManager defaultManager];
		NSString* Orig = [Dir stringByAppendingPathComponent:@"Unreal.ini.retail"];
		if( [FM fileExistsAtPath:UnrealIni] && ![FM fileExistsAtPath:Orig] )
			[FM copyItemAtPath:UnrealIni toPath:Orig error:nil];

		IniEdit( UnrealIni, ^(NSMutableArray* L)
		{
			// Drivers: always forced (retail ini points at WinDrv/SoftDrv/D3DDrv/Audio).
			IniSet( L, @"Engine.Engine", @"GameRenderDevice",     @"NOpenGLESDrv.NOpenGLESRenderDevice", YES );
			IniSet( L, @"Engine.Engine", @"WindowedRenderDevice", @"NOpenGLESDrv.NOpenGLESRenderDevice", YES );
			IniSet( L, @"Engine.Engine", @"AudioDevice",          @"NOpenALDrv.NOpenALAudioSubsystem",   YES );
			IniSet( L, @"Engine.Engine", @"ViewportManager",      @"NSDLDrv.NSDLClient",                 YES );
			IniSet( L, @"Engine.Engine", @"Render",               @"Render.Render",                      YES );
			IniSet( L, @"Engine.Engine", @"Console",              @"Engine.Console",                     NO );
			IniSet( L, @"Engine.Engine", @"GameEngine",           @"Engine.GameEngine",                  NO );
			IniSet( L, @"Engine.Engine", @"DefaultGame",          @"UnrealI.SinglePlayer",               NO );
			IniSet( L, @"Engine.Engine", @"NetworkDevice",        @"IpDrv.TcpNetDriver",                 NO );
			IniSet( L, @"Core.System", @"SavePath",  @"../Save",  NO );
			IniSet( L, @"Core.System", @"CachePath", @"../Cache", NO );
			IniSet( L, @"Core.System", @"CacheExt",  @".uxx",     NO );

			// Client / input.
			IniSet( L, @"NSDLDrv.NSDLClient", @"StartupFullscreen", @"True",  YES );
			IniSet( L, @"NSDLDrv.NSDLClient", @"UseJoystick",       @"True",  YES );
			IniSet( L, @"NSDLDrv.NSDLClient", @"LowDetailTextures", @"True",  YES ); // half-size mips: far less texture bandwidth
			IniSet( L, @"NSDLDrv.NSDLClient", @"Brightness",        @"0.5",   NO );
			IniSet( L, @"NSDLDrv.NSDLClient", @"DeadZoneXYZ",       @"0.10",  NO );
			IniSet( L, @"NSDLDrv.NSDLClient", @"DeadZoneRUV",       @"0.10",  NO );
			IniSet( L, @"NSDLDrv.NSDLClient", @"ScaleXYZ",          @"100.0", NO );
			IniSet( L, @"NSDLDrv.NSDLClient", @"ScaleRUV",          @"100.0", NO );
			IniSet( L, @"NSDLDrv.NSDLClient", @"InvertY",           @"False", NO );
			IniSet( L, @"NSDLDrv.NSDLClient", @"InvertV",           @"False", NO );

			// Renderer: conservative defaults for A5-class GPUs (user can raise them).
			IniSet( L, @"NOpenGLESDrv.NOpenGLESRenderDevice", @"SwapInterval",      @"1",    NO );
			IniSet( L, @"NOpenGLESDrv.NOpenGLESRenderDevice", @"Translucency",      @"True", NO );
			IniSet( L, @"NOpenGLESDrv.NOpenGLESRenderDevice", @"VolumetricLighting",@"False",YES );
			IniSet( L, @"NOpenGLESDrv.NOpenGLESRenderDevice", @"ShinySurfaces",     @"False",YES );
			IniSet( L, @"NOpenGLESDrv.NOpenGLESRenderDevice", @"Coronas",           @"False",YES );
			IniSet( L, @"NOpenGLESDrv.NOpenGLESRenderDevice", @"HighDetailActors",  @"False",YES );
			IniSet( L, @"NOpenGLESDrv.NOpenGLESRenderDevice", @"DetailTextures",    @"False",NO );

			// Audio: Apple's OpenAL has no EFX, so no reverb / HRTF.
			IniSet( L, @"NOpenALDrv.NOpenALAudioSubsystem", @"UseReverb",  @"False", YES );
			IniSet( L, @"NOpenALDrv.NOpenALAudioSubsystem", @"UseHRTF",    @"False", YES );
			IniSet( L, @"NOpenALDrv.NOpenALAudioSubsystem", @"OutputRate", @"44100", NO );
			IniSet( L, @"NOpenALDrv.NOpenALAudioSubsystem", @"MusicVolume",  @"63",  NO );
			IniSet( L, @"NOpenALDrv.NOpenALAudioSubsystem", @"SoundVolume",  @"127", NO );
			IniSet( L, @"NOpenALDrv.NOpenALAudioSubsystem", @"MasterVolume", @"255", NO );
			// Touch controls (iOS only).
			IniSet( L, @"IOSTouch", @"LookSensitivity", @"1.4", NO );
			IniSet( L, @"IOSTouch", @"ControlsScale",   @"1.0", NO );
			IniSet( L, @"IOSTouch", @"RenderScale",     @"0.6", YES );
		} );

		// Read the touch tunables back (clamped) for the on-screen controls.
		{
			NSString* Text = [NSString stringWithContentsOfFile:UnrealIni encoding:NSUTF8StringEncoding error:nil];
			if( !Text ) Text = [NSString stringWithContentsOfFile:UnrealIni encoding:NSISOLatin1StringEncoding error:nil];
			BOOL CR = NO; NSMutableArray* L = IniLines( Text ? Text : @"", &CR );
			BOOL In = NO;
			for( NSString* Raw in L )
			{
				NSString* T = Trim( Raw );
				if( [T hasPrefix:@"["] ) { In = ( [T caseInsensitiveCompare:@"[IOSTouch]"] == NSOrderedSame ); continue; }
				if( !In ) continue;
				NSRange Eq = [T rangeOfString:@"="];
				if( Eq.location == NSNotFound ) continue;
				NSString* K = Trim( [T substringToIndex:Eq.location] );
				float V = [Trim( [T substringFromIndex:Eq.location + 1] ) floatValue];
				if( [K caseInsensitiveCompare:@"LookSensitivity"] == NSOrderedSame && V > 0 ) GLookSens = MAX( 0.2f, MIN( 6.0f, V ) );
				if( [K caseInsensitiveCompare:@"ControlsScale"]   == NSOrderedSame && V > 0 ) GCtlScale = MAX( 0.6f, MIN( 1.6f, V ) );
				if( [K caseInsensitiveCompare:@"RenderScale"]     == NSOrderedSame && V > 0 ) GRenderScale = MAX( 0.4f, MIN( 1.0f, V ) );
			}
		}

		// Gamepad bindings (used by both the on-screen pad and MFi controllers).
		// Existing bindings are never overwritten.
		IniEdit( UserIni, ^(NSMutableArray* L)
		{
			IniSet( L, @"DefaultPlayer", @"Name",  @"Player", NO );
			IniSet( L, @"DefaultPlayer", @"Class", @"UnrealShare.MaleOne", NO );
			static const char* Bind[][2] = {
				{"LeftMouse","Fire"},{"RightMouse","AltFire"},
				{"Joy1","Jump"},{"Joy2","Duck"},{"Joy3","Grab"},{"Joy4","Walking"},
				{"Joy5","ActivateTranslator"},{"Joy7","ShowMenu"},
				{"Joy10","PrevWeapon"},{"Joy11","NextWeapon"},
				{"Joy12","AltFire"},{"Joy13","Fire"},
				{"JoyX","Axis aStrafe Speed=1"},{"JoyY","Axis aBaseY Speed=1"},
				{"JoyU","Axis aTurn Speed=1"},{"JoyV","Axis aLookUp Speed=-1"},
				{"JoyPovRight","NextWeapon"},{"JoyPovLeft","PrevWeapon"},
				{"JoyPovUp","InventoryPrevious"},{"JoyPovDown","InventoryNext"},
			};
			for( size_t i = 0; i < sizeof(Bind)/sizeof(Bind[0]); i++ )
				IniSet( L, @"Engine.Input", [NSString stringWithUTF8String:Bind[i][0]], [NSString stringWithUTF8String:Bind[i][1]], NO );
		} );
	}
}

// ---------------------------------------------------------------------------
// Virtual gamepad -> SDL controller events
// ---------------------------------------------------------------------------
static void PushAxis( SDL_GameControllerAxis Axis, int Value )
{
	static int Last[SDL_CONTROLLER_AXIS_MAX];
	if( Value > 32767 ) Value = 32767;
	if( Value < -32768 ) Value = -32768;
	if( Last[Axis] == Value ) return;
	Last[Axis] = Value;
	SDL_Event E; SDL_zero( E );
	E.type = SDL_CONTROLLERAXISMOTION;
	E.caxis.which = 0;
	E.caxis.axis = (Uint8)Axis;
	E.caxis.value = (Sint16)Value;
	SDL_PushEvent( &E );
}

static void PushButton( SDL_GameControllerButton Button, bool Down )
{
	SDL_Event E; SDL_zero( E );
	E.type = Down ? SDL_CONTROLLERBUTTONDOWN : SDL_CONTROLLERBUTTONUP;
	E.cbutton.which = 0;
	E.cbutton.button = (Uint8)Button;
	E.cbutton.state = Down ? SDL_PRESSED : SDL_RELEASED;
	SDL_PushEvent( &E );
}

static void PushEscape()
{
	for( int Down = 1; Down >= 0; Down-- )
	{
		SDL_Event E; SDL_zero( E );
		E.type = Down ? SDL_KEYDOWN : SDL_KEYUP;
		E.key.state = Down ? SDL_PRESSED : SDL_RELEASED;
		E.key.keysym.scancode = SDL_SCANCODE_ESCAPE;
		E.key.keysym.sym = SDLK_ESCAPE;
		SDL_PushEvent( &E );
	}
}

enum { PAD_BTN_FIRE, PAD_BTN_ALT, PAD_BTN_JUMP, PAD_BTN_DUCK, PAD_BTN_NEXT, PAD_BTN_PREV, PAD_BTN_COUNT };

// Layout is designed in points for a 768pt-tall screen (iPad 1024x768) and scaled by PadScale().
// Everything hangs off the bottom-right corner so it sits under the right thumb (an arc around FIRE).
struct PadBtnDef { const char* Label; CGFloat FromRight, FromBottom, Radius; };
static const PadBtnDef kBtn[PAD_BTN_COUNT] =
{
	{ "FIRE", 125, 125, 64 },
	{ "ALT",  268,  80, 44 },
	{ "JUMP",  96, 272, 48 },
	{ "DUCK", 252, 214, 40 },
	{ "NEXT",  62, 410, 36 },
	{ "PREV",  62, 496, 36 },
};

static const CGFloat kBtnIdleAlpha = 0.26;
static const CGFloat kBtnDownAlpha = 0.60;

static CGFloat PadScale( CGSize S )
{
	CGFloat K = S.height / 768.0;
	if( K < 0.75 ) K = 0.75;
	if( K > 1.5 ) K = 1.5;
	return K * GCtlScale;
}

static BOOL GMenuMode = NO;   // set by UE1PadView; in menus the buttons/stick drive the menu like arrow keys

static void PushKey( SDL_Scancode Sc, SDL_Keycode Sym, bool Down )
{
	SDL_Event E; SDL_zero( E );
	E.type = Down ? SDL_KEYDOWN : SDL_KEYUP;
	E.key.state = Down ? SDL_PRESSED : SDL_RELEASED;
	E.key.keysym.scancode = Sc;
	E.key.keysym.sym = Sym;
	SDL_PushEvent( &E );
}

// Menu navigation: NEXT/PREV = down/up, FIRE/JUMP = Enter (select), ALT = right, DUCK = Escape (back).
static void ApplyMenuButton( int Idx, bool Down )
{
	switch( Idx )
	{
		case PAD_BTN_NEXT: PushKey( SDL_SCANCODE_DOWN,   SDLK_DOWN,   Down ); break;
		case PAD_BTN_PREV: PushKey( SDL_SCANCODE_UP,     SDLK_UP,     Down ); break;
		case PAD_BTN_FIRE:
		case PAD_BTN_JUMP: PushKey( SDL_SCANCODE_RETURN, SDLK_RETURN, Down ); break;
		case PAD_BTN_ALT:  PushKey( SDL_SCANCODE_RIGHT,  SDLK_RIGHT,  Down ); break;
		case PAD_BTN_DUCK: PushKey( SDL_SCANCODE_ESCAPE, SDLK_ESCAPE, Down ); break;
	}
}

static void ApplyButton( int Idx, bool Down )
{
	if( GMenuMode ) { ApplyMenuButton( Idx, Down ); return; }
	switch( Idx )
	{
		case PAD_BTN_FIRE: PushAxis( SDL_CONTROLLER_AXIS_TRIGGERRIGHT, Down ? 32767 : 0 ); break;
		case PAD_BTN_ALT:  PushAxis( SDL_CONTROLLER_AXIS_TRIGGERLEFT,  Down ? 32767 : 0 ); break;
		case PAD_BTN_JUMP: PushButton( SDL_CONTROLLER_BUTTON_A, Down ); break;
		case PAD_BTN_DUCK: PushButton( SDL_CONTROLLER_BUTTON_B, Down ); break;
		case PAD_BTN_NEXT: PushButton( SDL_CONTROLLER_BUTTON_RIGHTSHOULDER, Down ); break;
		case PAD_BTN_PREV: PushButton( SDL_CONTROLLER_BUTTON_LEFTSHOULDER,  Down ); break;
	}
}

@interface UE1PadTouch : NSObject
{ @public int Role; int Btn; CGPoint Origin; }
@end
@implementation UE1PadTouch
@end

// MOVE = floating left stick, LOOK = drag anywhere on the right half (relative, like a mouse),
// BUTTON = on-screen button (FIRE also lets the same finger keep aiming), MENU = top-centre button.
enum { ROLE_NONE, ROLE_MOVE, ROLE_LOOK, ROLE_BUTTON, ROLE_MENU };

@interface UE1PadView : UIView
{
	NSMutableDictionary* Touches;
	UIView* BtnViews[PAD_BTN_COUNT];
	UIView* MenuView;
	UILabel* MenuLabel;
	UIView* StickBase;
	UIView* StickKnob;
	UIView* StickHint;
	CGFloat Scale;
	BOOL MenuMode;
	int HeldDir;            // menu stick: currently held arrow scancode (0 = none)
	CFAbsoluteTime NextRepeat;
}
- (void)releaseAll;
- (void)tick;
- (void)setMenuMode:(BOOL)InMenu;
@end

@implementation UE1PadView

static UIView* MakeCircle( CGFloat R, CGFloat Alpha )
{
	UIView* V = [[UIView alloc] initWithFrame:CGRectMake( 0, 0, R * 2, R * 2 )];
	V.backgroundColor = [UIColor colorWithWhite:1.0 alpha:Alpha];
	V.layer.cornerRadius = R;
	V.layer.borderWidth = 3;
	V.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
	V.userInteractionEnabled = NO;
	return V;
}

static UILabel* MakeLabel( CGRect Frame, NSString* Text, CGFloat Size )
{
	UILabel* L = [[UILabel alloc] initWithFrame:Frame];
	L.text = Text;
	L.textAlignment = NSTextAlignmentCenter;
	L.textColor = [UIColor whiteColor];
	L.font = [UIFont boldSystemFontOfSize:Size];
	L.backgroundColor = [UIColor clearColor];
	L.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.7];
	L.shadowOffset = CGSizeMake( 0, 1 );
	L.userInteractionEnabled = NO;
	return L;
}

- (instancetype)initWithFrame:(CGRect)Frame
{
	if( ( self = [super initWithFrame:Frame] ) )
	{
		Touches = [NSMutableDictionary dictionary];
		Scale = 1.0;
		MenuMode = NO;
		self.multipleTouchEnabled = YES;
		self.exclusiveTouch = NO;
		self.backgroundColor = [UIColor clearColor];
		self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		for( int i = 0; i < PAD_BTN_COUNT; i++ )
		{
			BtnViews[i] = MakeCircle( kBtn[i].Radius, kBtnIdleAlpha );
			CGFloat FontSize = ( i == PAD_BTN_FIRE ) ? 24 : ( kBtn[i].Radius >= 40 ? 18 : 14 );
			[BtnViews[i] addSubview:MakeLabel( BtnViews[i].bounds, [NSString stringWithUTF8String:kBtn[i].Label], FontSize )];
			[self addSubview:BtnViews[i]];
		}
		MenuView = [[UIView alloc] initWithFrame:CGRectMake( 0, 0, 132, 48 )];
		MenuView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.30];
		MenuView.layer.cornerRadius = 12;
		MenuView.layer.borderWidth = 3;
		MenuView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
		MenuLabel = MakeLabel( MenuView.bounds, @"MENU", 18 );
		[MenuView addSubview:MenuLabel];
		MenuView.userInteractionEnabled = NO;
		[self addSubview:MenuView];
		StickHint = MakeCircle( 80, 0.06 );  [self addSubview:StickHint];   // where the stick will appear
		StickBase = MakeCircle( 80, 0.12 );  StickBase.hidden = YES; [self addSubview:StickBase];
		StickKnob = MakeCircle( 34, 0.38 );  StickKnob.hidden = YES; [self addSubview:StickKnob];
		[self setNeedsLayout];
	}
	return self;
}

- (void)setMenuMode:(BOOL)InMenu
{
	if( InMenu == MenuMode ) return;
	[self releaseAll];
	MenuMode = InMenu;
	GMenuMode = InMenu;
	// buttons AND the stick zone stay visible and active in menus
	MenuLabel.text = InMenu ? @"CLOSE" : @"MENU";
	[self setNeedsLayout];
}

- (void)layoutSubviews
{
	[super layoutSubviews];
	CGRect B = self.bounds;
	Scale = PadScale( B.size );
	for( int i = 0; i < PAD_BTN_COUNT; i++ )
	{
		BtnViews[i].transform = CGAffineTransformIdentity;
		BtnViews[i].center = CGPointMake( B.size.width - kBtn[i].FromRight * Scale, B.size.height - kBtn[i].FromBottom * Scale );
		BtnViews[i].transform = CGAffineTransformMakeScale( Scale, Scale );
	}
	MenuView.transform = CGAffineTransformIdentity;
	MenuView.center = CGPointMake( B.size.width * 0.5, 36 * Scale );
	MenuView.transform = CGAffineTransformMakeScale( Scale, Scale );
	StickHint.transform = CGAffineTransformIdentity;
	StickHint.center = CGPointMake( 150 * Scale, B.size.height - 150 * Scale );
	StickHint.transform = CGAffineTransformMakeScale( Scale, Scale );
	StickBase.transform = CGAffineTransformMakeScale( Scale, Scale );
	StickKnob.transform = CGAffineTransformMakeScale( Scale, Scale );
}

- (CGRect)menuHitRect { return CGRectInset( MenuView.frame, -16, -16 ); }

- (BOOL)inStickZone:(CGPoint)P
{
	CGPoint C = StickHint.center;
	CGFloat R = 110 * Scale;
	return ( P.x - C.x ) * ( P.x - C.x ) + ( P.y - C.y ) * ( P.y - C.y ) <= R * R;
}

// In the menu only the buttons + CLOSE are ours; every other touch falls through to SDL (touch -> mouse).
- (UIView*)hitTest:(CGPoint)P withEvent:(UIEvent*)E
{
	if( self.hidden ) return nil;
	if( MenuMode ) return ( CGRectContainsPoint( [self menuHitRect], P ) || [self buttonAt:P] >= 0 || [self inStickZone:P] ) ? self : nil;
	return self;
}

- (int)buttonAt:(CGPoint)P
{
	CGRect B = self.bounds;
	int Best = -1; CGFloat BestD = 1e9;
	for( int i = 0; i < PAD_BTN_COUNT; i++ )
	{
		CGPoint C = CGPointMake( B.size.width - kBtn[i].FromRight * Scale, B.size.height - kBtn[i].FromBottom * Scale );
		CGFloat R = ( kBtn[i].Radius + 22 ) * Scale; // generous hit area: thumbs are fat
		CGFloat D2 = ( P.x - C.x ) * ( P.x - C.x ) + ( P.y - C.y ) * ( P.y - C.y );
		if( D2 <= R * R && D2 < BestD ) { BestD = D2; Best = i; }
	}
	return Best;
}

- (BOOL)hasRole:(int)Role
{
	for( UE1PadTouch* T in [Touches allValues] ) if( T->Role == Role ) return YES;
	return NO;
}

- (void)updateStick:(UE1PadTouch*)T at:(CGPoint)P
{
	const CGFloat Radius = 80.0 * Scale;
	CGFloat DX = ( P.x - T->Origin.x ) / Radius, DY = ( P.y - T->Origin.y ) / Radius;
	CGFloat Len = sqrt( DX * DX + DY * DY );
	if( Len > 1.0 ) { DX /= Len; DY /= Len; Len = 1.0; }
	if( MenuMode )
	{
		// Menu: stick = arrow keys (dominant axis, 0.5 threshold), auto-repeat from -tick.
		int Dir = 0;
		if( Len >= 0.5 ) Dir = ( fabs( DX ) > fabs( DY ) ) ? ( DX > 0 ? SDL_SCANCODE_RIGHT : SDL_SCANCODE_LEFT ) : ( DY > 0 ? SDL_SCANCODE_DOWN : SDL_SCANCODE_UP );
		if( Dir != HeldDir )
		{
			[self releaseDir];
			if( Dir ) { [self pressDir:Dir]; NextRepeat = CFAbsoluteTimeGetCurrent() + 0.40; }
		}
		StickKnob.center = CGPointMake( T->Origin.x + DX * Radius * 0.9, T->Origin.y + DY * Radius * 0.9 );
		return;
	}
	const CGFloat Dead = 0.12;
	if( Len < Dead ) { DX = DY = 0; }
	else { CGFloat K = ( Len - Dead ) / ( 1.0 - Dead ) / Len; DX *= K; DY *= K; }
	// SDL convention: up / left are negative; screen Y grows downward -> same sign.
	PushAxis( SDL_CONTROLLER_AXIS_LEFTX, (int)( DX * 32767 ) );
	PushAxis( SDL_CONTROLLER_AXIS_LEFTY, (int)( DY * 32767 ) );
	StickKnob.center = CGPointMake( T->Origin.x + DX * Radius * 0.9, T->Origin.y + DY * Radius * 0.9 );
}

- (void)pressDir:(int)Dir
{
	HeldDir = Dir;
	SDL_Keycode Sym = Dir == SDL_SCANCODE_UP ? SDLK_UP : Dir == SDL_SCANCODE_DOWN ? SDLK_DOWN : Dir == SDL_SCANCODE_LEFT ? SDLK_LEFT : SDLK_RIGHT;
	PushKey( (SDL_Scancode)Dir, Sym, true );
}

- (void)releaseDir
{
	if( !HeldDir ) return;
	int Dir = HeldDir; HeldDir = 0;
	SDL_Keycode Sym = Dir == SDL_SCANCODE_UP ? SDLK_UP : Dir == SDL_SCANCODE_DOWN ? SDLK_DOWN : Dir == SDL_SCANCODE_LEFT ? SDLK_LEFT : SDLK_RIGHT;
	PushKey( (SDL_Scancode)Dir, Sym, false );
}

- (void)tick
{
	if( HeldDir && CFAbsoluteTimeGetCurrent() >= NextRepeat )
	{
		int Dir = HeldDir;
		SDL_Keycode Sym = Dir == SDL_SCANCODE_UP ? SDLK_UP : Dir == SDL_SCANCODE_DOWN ? SDLK_DOWN : Dir == SDL_SCANCODE_LEFT ? SDLK_LEFT : SDLK_RIGHT;
		PushKey( (SDL_Scancode)Dir, Sym, false );
		PushKey( (SDL_Scancode)Dir, Sym, true );
		NextRepeat = CFAbsoluteTimeGetCurrent() + 0.13;
	}
}

- (void)setButton:(int)Idx pressed:(BOOL)Down
{
	BtnViews[Idx].backgroundColor = [UIColor colorWithWhite:1.0 alpha:Down ? kBtnDownAlpha : kBtnIdleAlpha];
}

- (void)touchesBegan:(NSSet*)Set withEvent:(UIEvent*)E
{
	CGRect B = self.bounds;
	for( UITouch* U in Set )
	{
		CGPoint P = [U locationInView:self];
		UE1PadTouch* T = [UE1PadTouch new];
		T->Origin = P; T->Btn = -1; T->Role = ROLE_NONE;
		if( CGRectContainsPoint( [self menuHitRect], P ) )
		{
			T->Role = ROLE_MENU;
			MenuView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.60];
			PushEscape();
		}
		else
		{
			int Bi = [self buttonAt:P];
			if( Bi >= 0 )
			{
				T->Role = ROLE_BUTTON; T->Btn = Bi; ApplyButton( Bi, true );
				[self setButton:Bi pressed:YES];
			}
			else if( MenuMode )
			{
				if( [self inStickZone:P] && ![self hasRole:ROLE_MOVE] ) T->Role = ROLE_MOVE;
			}
			else if( P.x < B.size.width * 0.5 )
			{
				if( ![self hasRole:ROLE_MOVE] ) T->Role = ROLE_MOVE;
			}
			else if( ![self hasRole:ROLE_LOOK] ) T->Role = ROLE_LOOK;
		}
		if( T->Role == ROLE_MOVE )
		{
			StickBase.center = P; StickKnob.center = P;
			StickBase.hidden = NO; StickKnob.hidden = NO; StickHint.hidden = YES;
		}
		[Touches setObject:T forKey:[NSValue valueWithNonretainedObject:U]];
	}
}

- (void)touchesMoved:(NSSet*)Set withEvent:(UIEvent*)E
{
	for( UITouch* U in Set )
	{
		UE1PadTouch* T = [Touches objectForKey:[NSValue valueWithNonretainedObject:U]];
		if( !T ) continue;
		if( T->Role == ROLE_MOVE )
			[self updateStick:T at:[U locationInView:self]];
		else if( T->Role == ROLE_LOOK || ( T->Role == ROLE_BUTTON && T->Btn == PAD_BTN_FIRE ) )
		{
			// Relative drag, exactly like moving a mouse: no stick, no recentring.
			CGPoint P = [U locationInView:self], Q = [U previousLocationInView:self];
			UE1IOSPushLook( (float)( P.x - Q.x ) * GLookSens, (float)( P.y - Q.y ) * GLookSens );
		}
	}
}

- (void)endTouch:(UE1PadTouch*)T
{
	if( T->Role == ROLE_BUTTON )
	{
		ApplyButton( T->Btn, false );
		[self setButton:T->Btn pressed:NO];
	}
	else if( T->Role == ROLE_MOVE )
	{
		[self releaseDir];
		PushAxis( SDL_CONTROLLER_AXIS_LEFTX, 0 );
		PushAxis( SDL_CONTROLLER_AXIS_LEFTY, 0 );
		StickBase.hidden = YES; StickKnob.hidden = YES; StickHint.hidden = NO;
	}
	else if( T->Role == ROLE_MENU )
	{
		MenuView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.30];
	}
}

- (void)touchesEnded:(NSSet*)Set withEvent:(UIEvent*)E
{
	for( UITouch* U in Set )
	{
		NSValue* K = [NSValue valueWithNonretainedObject:U];
		UE1PadTouch* T = [Touches objectForKey:K];
		if( T ) { [self endTouch:T]; [Touches removeObjectForKey:K]; }
	}
}

- (void)touchesCancelled:(NSSet*)Set withEvent:(UIEvent*)E { [self touchesEnded:Set withEvent:E]; }

- (void)releaseAll
{
	for( UE1PadTouch* T in [Touches allValues] ) [self endTouch:T];
	[Touches removeAllObjects];
}
@end

// ---------------------------------------------------------------------------
// Per-frame hook from NSDLViewport + lifecycle
// ---------------------------------------------------------------------------
static UE1PadView* GPad = nil;
static BOOL GLifecycleWatch = NO;

static int SDLCALL LifecycleWatch( void* /*UserData*/, SDL_Event* E )
{
	// Delivered synchronously: the process is suspended right after this returns.
	if( E->type == SDL_APP_WILLENTERBACKGROUND )      UE1AndroidSetAudioSuspended( 1 );
	else if( E->type == SDL_APP_DIDENTERFOREGROUND )  UE1AndroidSetAudioSuspended( 0 );
	return 0;
}

static BOOL HasMFiController( void )
{
	if( !NSClassFromString( @"GCController" ) ) return NO;
	return [[GCController controllers] count] > 0;
}

extern "C" void UE1IOSSetUIState( int InMenu, int /*Typing*/ )
{
	@autoreleasepool
	{
		if( !GLifecycleWatch ) { SDL_AddEventWatch( LifecycleWatch, NULL ); GLifecycleWatch = YES; }

		// Fullscreen: iOS 7 can bring the status bar back (alerts, app switcher, rotation).
		// Keep it hidden and keep the screen awake. Cheap enough to check every frame.
		{
			UIApplication* App = [UIApplication sharedApplication];
			if( !App.statusBarHidden ) [App setStatusBarHidden:YES withAnimation:UIStatusBarAnimationNone];
			if( !App.idleTimerDisabled ) App.idleTimerDisabled = YES;
		}

		UIWindow* Win = [[UIApplication sharedApplication] keyWindow];
		if( !Win ) return;
		UIView* Host = Win.rootViewController ? Win.rootViewController.view : Win;

		// iOS 7 iPad: SDL's view can stay at the portrait size (768x1024) in a landscape app, so the GL surface is
		// cropped and only part of the screen is drawn. Log the geometry and force the root view to landscape size.
		{
			UIApplication* App = [UIApplication sharedApplication];
			const UIInterfaceOrientation O = App.statusBarOrientation;
			const BOOL Land = UIInterfaceOrientationIsLandscape( O );
			const CGSize SB = [UIScreen mainScreen].bounds.size;
			const CGFloat Long = SB.width > SB.height ? SB.width : SB.height;
			const CGFloat Short = SB.width > SB.height ? SB.height : SB.width;
			CGSize HB = Host.bounds.size;
			static CGSize LastHB = CGSizeZero; static int LastO = -99; static CGSize LastWB = CGSizeZero;
			if( HB.width != LastHB.width || HB.height != LastHB.height || (int)O != LastO || Win.bounds.size.width != LastWB.width )
			{
				char Buf[300];
				snprintf( Buf, sizeof(Buf), "ui: orient=%d screen=%.0fx%.0f window=%.0fx%.0f host=%.0fx%.0f scale=%.1f",
					(int)O, SB.width, SB.height, Win.bounds.size.width, Win.bounds.size.height, HB.width, HB.height, (double)[UIScreen mainScreen].scale );
				UE1IOSLog( Buf );
				LastHB = HB; LastO = (int)O; LastWB = Win.bounds.size;
			}
			if( Land && HB.height > HB.width )
			{
				Host.bounds = CGRectMake( 0, 0, Long, Short );
				[Host setNeedsLayout]; [Host layoutIfNeeded];
				UE1IOSLog( "ui: host bounds forced to landscape" );
			}
			else if( !Land )
			{
				static CFAbsoluteTime LastTry = 0;
				CFAbsoluteTime Now = CFAbsoluteTimeGetCurrent();
				if( Now - LastTry > 1.0 )
				{
					LastTry = Now;
					[[UIDevice currentDevice] setValue:[NSNumber numberWithInt:(int)UIInterfaceOrientationLandscapeRight] forKey:@"orientation"];
					[UIViewController attemptRotationToDeviceOrientation];
				}
			}
		}

		BOOL Fresh = NO;
		if( !GPad || GPad.superview != Host )
		{
			[GPad removeFromSuperview];
			GPad = [[UE1PadView alloc] initWithFrame:Host.bounds];
			[Host addSubview:GPad];
			Fresh = YES;
		}
		// The pad stays up in menus (only its MENU/CLOSE button is active there); an MFi pad replaces it.
		const BOOL Hide = HasMFiController();
		if( Hide != GPad.hidden || Fresh )
		{
			if( Hide ) [GPad releaseAll];
			GPad.hidden = Hide;
			if( !Hide ) [Host bringSubviewToFront:GPad];
		}
		[GPad setMenuMode:( InMenu != 0 )];
		[GPad tick];

		// Make the GL view fill its parent (the picture was drawn into only part of the screen).
		{
			static __weak UIView* GLView = nil;
			if( !GLView )
			{
				NSMutableArray* Stack = [NSMutableArray arrayWithObject:Win];
				while( [Stack count] && !GLView )
				{
					UIView* V = [Stack lastObject]; [Stack removeLastObject];
					if( [NSStringFromClass( [V.layer class] ) isEqualToString:@"CAEAGLLayer"] ) { GLView = V; break; }
					for( UIView* S in V.subviews ) if( S != GPad ) [Stack addObject:S];
				}
				if( GLView )
				{
					char Buf[300];
					snprintf( Buf, sizeof(Buf), "ui: glview %s frame=%.0f,%.0f %.0fx%.0f bounds=%.0fx%.0f super=%s %.0fx%.0f scale=%.1f",
						object_getClassName( GLView ), GLView.frame.origin.x, GLView.frame.origin.y, GLView.frame.size.width, GLView.frame.size.height,
						GLView.bounds.size.width, GLView.bounds.size.height,
						GLView.superview ? object_getClassName( GLView.superview ) : "none",
						GLView.superview ? GLView.superview.bounds.size.width : 0.0, GLView.superview ? GLView.superview.bounds.size.height : 0.0,
						(double)GLView.contentScaleFactor );
					UE1IOSLog( Buf );
				}
			}
			UIView* Par = GLView.superview;
			if( GLView && Par && ( fabs( GLView.frame.size.width - Par.bounds.size.width ) > 1 || fabs( GLView.frame.size.height - Par.bounds.size.height ) > 1 || fabs( GLView.frame.origin.x ) > 1 || fabs( GLView.frame.origin.y ) > 1 ) )
			{
				char Buf[200];
				snprintf( Buf, sizeof(Buf), "ui: glview frame %.0fx%.0f -> parent %.0fx%.0f", GLView.frame.size.width, GLView.frame.size.height, Par.bounds.size.width, Par.bounds.size.height );
				UE1IOSLog( Buf );
				GLView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
				GLView.frame = Par.bounds;
			}
			// Render below native resolution (the system upscales): the single biggest speed-up on an iPad 1.
			if( GLView )
			{
				const CGFloat Want = [UIScreen mainScreen].scale * GRenderScale;
				if( fabs( GLView.contentScaleFactor - Want ) > 0.01 )
				{
					GLView.contentScaleFactor = Want;
					[GLView setNeedsLayout];
					char Buf[120];
					snprintf( Buf, sizeof(Buf), "ui: render scale -> %.2f", (double)Want );
					UE1IOSLog( Buf );
				}
			}
		}
	}
}
