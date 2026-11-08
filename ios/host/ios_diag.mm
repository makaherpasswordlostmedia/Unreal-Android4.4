// ios_diag.mm - persistent log + crash/exception/hang diagnostics for the iOS host.
//
// Everything goes to <App>/Documents/unreal_ios.log (and NSLog):
//   * engine debugf()/appError() lines (mirrored from UnPlat.cpp)
//   * SDL_Log / SDL_SetError-style messages
//   * fatal signals (SEGV/BUS/ILL/ABRT/FPE/TRAP) with a backtrace
//   * uncaught NSException and std::terminate with the exception text
//   * a heartbeat with the last log line, so a hang/black screen shows WHERE it stopped
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <SDL2/SDL.h>
#include <execinfo.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <exception>

extern "C" const char* UE1IOSDocumentsDir( void );

static int GFd = -1;
static pthread_mutex_t GLock = PTHREAD_MUTEX_INITIALIZER;
static char GLast[256] = "(nothing logged yet)";

static void RawWrite( const char* S )
{
	if( GFd < 0 || !S ) return;
	size_t N = strlen( S );
	while( N )
	{
		ssize_t W = write( GFd, S, N );
		if( W <= 0 ) break;
		S += W; N -= (size_t)W;
	}
}

static void EnsureOpen( void )
{
	if( GFd >= 0 ) return;
	char Path[1100];
	snprintf( Path, sizeof(Path), "%s/unreal_ios.log", UE1IOSDocumentsDir() );
	GFd = open( Path, O_WRONLY | O_CREAT | O_APPEND, 0644 );
}

static void LogLine( const char* Msg, bool UpdateLast )
{
	if( !Msg ) return;
	pthread_mutex_lock( &GLock );
	EnsureOpen();
	char Line[1400], Ts[16];
	time_t Now = time( NULL ); struct tm Tm; localtime_r( &Now, &Tm );
	strftime( Ts, sizeof(Ts), "%H:%M:%S", &Tm );
	snprintf( Line, sizeof(Line), "[%s] %.1300s\n", Ts, Msg );
	RawWrite( Line );
	if( UpdateLast ) strlcpy( GLast, Msg, sizeof(GLast) );
	pthread_mutex_unlock( &GLock );
}

extern "C" void UE1IOSLog( const char* Msg )
{
	LogLine( Msg, true );
	if( Msg ) NSLog( @"[Unreal] %s", Msg );
}

static void CrashHandler( int Sig, siginfo_t* Si, void* )
{
	char B[400];
	snprintf( B, sizeof(B), "\n*** CRASH: signal %d (%s) fault addr=%p\n*** last log line: %s\n",
		Sig, strsignal( Sig ), Si ? Si->si_addr : NULL, GLast );
	RawWrite( B );
	void* Bt[64]; int N = backtrace( Bt, 64 );
	if( GFd >= 0 ) backtrace_symbols_fd( Bt, N, GFd );
	RawWrite( "*** end of crash report\n" );
	signal( Sig, SIG_DFL );
	raise( Sig );
}

static void TerminateHandler( void )
{
	static int Busy = 0;
	if( !Busy )
	{
		Busy = 1;
		char B[600];
		try { throw; }
		catch( const std::exception& E ) { snprintf( B, sizeof(B), "std::exception: %s", E.what() ); }
		catch( const char* S )           { snprintf( B, sizeof(B), "thrown const char*: %s", S ? S : "(null)" ); }
		catch( int I )                   { snprintf( B, sizeof(B), "thrown int: %d (Unreal appError?)", I ); }
		catch( ... )                     { snprintf( B, sizeof(B), "unknown exception" ); }
		char M[800];
		snprintf( M, sizeof(M), "*** std::terminate: %s | last log line: %s", B, GLast );
		LogLine( M, false );
		void* Bt[64]; int N = backtrace( Bt, 64 );
		if( GFd >= 0 ) backtrace_symbols_fd( Bt, N, GFd );
	}
	abort();
}

static void ObjCExceptionHandler( NSException* E )
{
	NSString* S = [NSString stringWithFormat:@"*** Uncaught NSException %@: %@\n%@", E.name, E.reason, [E callStackSymbols]];
	LogLine( [S UTF8String], false );
}

static void SDLCALL SDLLogCB( void*, int Cat, SDL_LogPriority Pri, const char* Msg )
{
	char B[1100];
	snprintf( B, sizeof(B), "SDL[cat=%d pri=%d]: %s", Cat, (int)Pri, Msg ? Msg : "" );
	LogLine( B, true );
}

static void* HeartbeatThread( void* )
{
	int T = 0;
	for( ;; )
	{
		sleep( T < 60 ? 5 : 30 );
		T += ( T < 60 ? 5 : 30 );
		char B[400];
		snprintf( B, sizeof(B), "heartbeat +%ds | last log line: %s", T, GLast );
		LogLine( B, false );
	}
	return NULL;
}

__attribute__((constructor)) static void UE1IOSDiagInit( void )
{
	@autoreleasepool
	{
		pthread_mutex_lock( &GLock ); EnsureOpen(); pthread_mutex_unlock( &GLock );
		char H[300];
		snprintf( H, sizeof(H), "\n==== Unreal iOS launch | build %s %s | iOS %s | %s ====",
			__DATE__, __TIME__, [[[UIDevice currentDevice] systemVersion] UTF8String], [[[UIDevice currentDevice] model] UTF8String] );
		LogLine( H, true );
	}
	static char AltStack[64 * 1024];
	stack_t Ss; Ss.ss_sp = AltStack; Ss.ss_size = sizeof(AltStack); Ss.ss_flags = 0;
	sigaltstack( &Ss, NULL );
	struct sigaction Sa; memset( &Sa, 0, sizeof(Sa) );
	Sa.sa_sigaction = CrashHandler;
	Sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND;
	sigemptyset( &Sa.sa_mask );
	const int Sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP };
	for( size_t i = 0; i < sizeof(Sigs)/sizeof(Sigs[0]); i++ ) sigaction( Sigs[i], &Sa, NULL );
	std::set_terminate( TerminateHandler );
	NSSetUncaughtExceptionHandler( &ObjCExceptionHandler );
	SDL_LogSetAllPriority( SDL_LOG_PRIORITY_INFO );
	SDL_LogSetOutputFunction( SDLLogCB, NULL );
	pthread_t Th;
	if( pthread_create( &Th, NULL, HeartbeatThread, NULL ) == 0 ) pthread_detach( Th );
	LogLine( "diag: crash/exception/SDL handlers + heartbeat installed", true );
}
