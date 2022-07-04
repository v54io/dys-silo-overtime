#include <sourcemod>
#include <sdktools>

#include "MemoryExLite.inc"

#pragma newdecls required // git gud
#pragma semicolon 1 // git gud


public Plugin myinfo =
{
	name = "Silo Overtime™",
	author = "SEA.LEVEL.RISES™",
	description = "Adds 1 minute to remaining round time when the launch starts within the last minute.",
	version = "0.2",
	url = "sealevelrises.net"
}


char g_sCurrentMap[64];
bool g_bFullyHooked = false; // master switch
bool g_bCountdownBonusTime = false; // have we awarded bonus time
bool g_bCountdownBeginHooked = false;
int g_iCountdownAbortHooked = 0; // should end up being 2
bool g_bLaunchResultHooked = false;
float g_fTimerDelta = 61.0; // how much time should be added and subtracted to game clocks
bool g_bDebugMode = false;


Handle g_hGameConf;
Handle g_hNotifyNetworkStateChanged;
Handle g_hGetRoundTimeLeft;
Handle g_hGetRoundTimeElapsed;

Pointer gpGlobals = nullptr;
Pointer g_pGameRules = nullptr;
Pointer g_pRoundTimeLimit = nullptr;

/* offsets of interest */
int g_iCurtimeOffset = 0xc; // gpGlobals->curtime
int g_iRoundEndTimeOffset = 0x2004; // g_pGameRules->[round end time]

char g_sOvertimeEnabled1[] = "\x04[OVERTIME ENABLED]\x01 Starting the launch sequence in the last minute will add an extra minute to the clock.";
char g_sOvertimeEnabled2[] = "\x04[OVERTIME ENABLED]\x01 Aborting the launch will remove bonus time.";
char g_sPunksShouldLaunch[] = "\x04[OVERTIME ENABLED]\x01 Punks can still launch the missile with less than 60 seconds left!";
char g_sOvertimeActive[] = "\x05[OVERTIME ACTIVE]\x01 An extra minute has been added to the clock.  Abort the launch to remove bonus time!";

char g_sGameConfigFile[255] = "sdktools.games/custom/game.dystopia";
Handle g_Timer_RoundStartOverTimeReminders = INVALID_HANDLE;
Handle g_Timer_OvertimeReminder120 = INVALID_HANDLE;
Handle g_Timer_OvertimeReminder90 = INVALID_HANDLE;
Handle g_Timer_OvertimeReminder60 = INVALID_HANDLE;


public void OnPluginStart() {
	char game[64];
	GetGameFolderName( game, sizeof(game) );

	if ( !StrEqual( game, "dystopia", false ) )
		return;
	
	// RegAdminCmd( "so_status", OvertimeStatus, ADMFLAG_RCON );
	
	ConVar cvGameConfig = CreateConVar( "so_gameconfig", g_sGameConfigFile );
	cvGameConfig.GetString( g_sGameConfigFile, sizeof(g_sGameConfigFile) );
	HookConVarChange( cvGameConfig, ConVar_GameConfig );
	
	ConVar cvDebugMode = CreateConVar( "so_debug", "0", _, _, true, 0.0, true, 1.0 );
	g_bDebugMode = cvDebugMode.BoolValue;
	HookConVarChange( cvDebugMode, ConVar_DebugMode );
}

public void OnMapStart() {
	OnMapEnd();
	
	GetCurrentMap( g_sCurrentMap, sizeof(g_sCurrentMap) );
	
	if ( 0 != StrContains( g_sCurrentMap, "dys_silo", false ) )
		return;
	

	g_bCountdownBonusTime = false;
	g_bCountdownBeginHooked = false;
	g_iCountdownAbortHooked = 0;
	g_bLaunchResultHooked = false;
	
	gpGlobals = nullptr;
	g_pGameRules = nullptr;
	
	HookEvent( "round_restart", Event_RoundRestart, EventHookMode_Post );
	
	HookLaunchSequence();
}

public void OnMapEnd() {
	g_bFullyHooked = false;
	KillOvertimeReminderTimers();
}

public void OnClientPutInServer( int client ) {
	if ( !g_bFullyHooked )
		return;
	
	CreateTimer( 10.0, Timer_OvertimeNotice, client, TIMER_FLAG_NO_MAPCHANGE );	
}

Action Timer_OvertimeNotice( Handle timer, int client ) {
	if ( g_bCountdownBonusTime ) {
		PrintToChat(
			client,
			"%s",
			g_sOvertimeActive
		);
	} else {
		PrintToChat(
			client,
			"%s",
			g_sOvertimeEnabled1
		);
		PrintToChat(
			client,
			"%s",
			g_sOvertimeEnabled2
		);
	}
	
	return Plugin_Stop;
}

void ConVar_DebugMode( ConVar convar, const char[] oldValue, const char[] newValue ) {
	g_bDebugMode = convar.BoolValue;
}

void ConVar_GameConfig( ConVar convar, const char[] oldValue, const char[] newValue ) {
	convar.GetString( g_sGameConfigFile, sizeof(g_sGameConfigFile) );
}

Action Event_RoundRestart( Event event, const char[] name, bool dontBroadcast ) {
	HookLaunchSequence(true);
}

void KillOvertimeReminderTimers() {
	if ( INVALID_HANDLE != g_Timer_RoundStartOverTimeReminders ) {
		KillTimer(g_Timer_RoundStartOverTimeReminders);
		g_Timer_RoundStartOverTimeReminders = INVALID_HANDLE;
	}
	if ( INVALID_HANDLE != g_Timer_OvertimeReminder120 ) {
		KillTimer(g_Timer_OvertimeReminder120);
		g_Timer_OvertimeReminder120 = INVALID_HANDLE;
	}
	if ( INVALID_HANDLE != g_Timer_OvertimeReminder90 ) {
		KillTimer(g_Timer_OvertimeReminder90);
		g_Timer_OvertimeReminder90 = INVALID_HANDLE;
	}
	if ( INVALID_HANDLE != g_Timer_OvertimeReminder60 ) {
		KillTimer(g_Timer_OvertimeReminder60);
		g_Timer_OvertimeReminder60 = INVALID_HANDLE;
	}
}

void HookLaunchSequence( bool entities_only=false ) {
	g_bFullyHooked = false;
	g_bCountdownBonusTime = false;
	g_bCountdownBeginHooked = false;
	g_iCountdownAbortHooked = 0;
	g_bLaunchResultHooked = false;
	
	if ( !entities_only ) {
		g_hGameConf = LoadGameConfigFile(g_sGameConfigFile);
		if ( INVALID_HANDLE == g_hGameConf )
			SetFailState( "Could not locate game config file \"%s\"", g_sGameConfigFile );
		
		gpGlobals = GameConfGetAddress( g_hGameConf, "gpGlobals" );
		if ( nullptr == gpGlobals )
			SetFailState( "Failed to find gpGlobals" );
		
		g_pGameRules = GameConfGetAddress( g_hGameConf, "g_pGameRules" );
		if ( nullptr == g_pGameRules )
			SetFailState( "Failed to find g_pGameRules" );
		
		g_pRoundTimeLimit = GameConfGetAddress( g_hGameConf, "RoundTimeLimit" );
		if ( nullptr == g_pRoundTimeLimit )
			SetFailState( "Failed to find g_pRoundTimeLimit" );
		
		/* NotifyNetworkStateChanged */
		StartPrepSDKCall(SDKCall_Static);
		PrepSDKCall_SetFromConf( g_hGameConf, SDKConf_Signature, "NotifyNetworkStateChanged" );
		PrepSDKCall_SetReturnInfo( SDKType_PlainOldData, SDKPass_Plain );
		g_hNotifyNetworkStateChanged = EndPrepSDKCall();
		if ( INVALID_HANDLE == g_hNotifyNetworkStateChanged )
			SetFailState( "Failed to hook NotifyNetworkStateChanged()" );
		
		/* GetRoundTimeLeft */
		StartPrepSDKCall(SDKCall_GameRules);
		PrepSDKCall_SetFromConf( g_hGameConf, SDKConf_Signature, "GetRoundTimeLeft" );
		PrepSDKCall_SetReturnInfo( SDKType_Float, SDKPass_ByValue );
		g_hGetRoundTimeLeft = EndPrepSDKCall();
		if ( INVALID_HANDLE == g_hGetRoundTimeLeft )
			SetFailState( "Failed to hook GetRoundTimeLeft()" );
		
		/* GetRoundTimeElapsed */
		StartPrepSDKCall(SDKCall_GameRules);
		PrepSDKCall_SetFromConf( g_hGameConf, SDKConf_Signature, "GetRoundTimeElapsed" );
		PrepSDKCall_SetReturnInfo( SDKType_Float, SDKPass_ByValue );
		g_hGetRoundTimeElapsed = EndPrepSDKCall();
		if ( INVALID_HANDLE == g_hGetRoundTimeElapsed )
			SetFailState( "Failed to hook GetRoundTimeElapsed()" );
		
	}
	
	int ent = -1;
	char targetname[64];
	
	// find countdown logic ents
	while ( -1 != (ent = FindEntityByClassname( ent, "logic_relay" )) ) {
		GetEntPropString( ent, Prop_Data, "m_iName", targetname, sizeof(targetname) );
		
		if ( !g_bCountdownBeginHooked && StrEqual( targetname, "counter_relay", false ) ) {
			HookSingleEntityOutput( ent, "OnTrigger", CountdownBegin, false );
			g_bCountdownBeginHooked = true;
		}
		
		if ( 2 != g_iCountdownAbortHooked && 0 == StrContains( targetname, "counter_relay_cancelled_", false ) ) {
			HookSingleEntityOutput( ent, "OnTrigger", CountdownAbort, false );
			g_iCountdownAbortHooked += 1;
		}
		
		if ( g_bCountdownBeginHooked && 2 == g_iCountdownAbortHooked )
			break;
		
	}
	if ( !g_bCountdownBeginHooked || 2 != g_iCountdownAbortHooked )
		SetFailState( "Failed to hook launch sequence entities." );
	
	
	// find launch successful objective ent
	while ( -1 != (ent = FindEntityByClassname( ent, "dys_objective" )) ) {
		GetEntPropString( ent, Prop_Data, "m_iName", targetname, sizeof(targetname) );
		
		if ( StrEqual( targetname, "objective_5", false ) ) {
			HookSingleEntityOutput( ent, "OnPunks", LaunchResult, false );
			HookSingleEntityOutput( ent, "OnCorps", LaunchResult, false );
			g_bLaunchResultHooked = true;
			break;
		}
	}
	if ( !g_bLaunchResultHooked )
		SetFailState( "Failed to hook objective_5." );
	
	g_bFullyHooked = true;
	
	KillOvertimeReminderTimers();
	CreateOvertimeReminderTimers();
}

/*
 * CreateOvertimeReminderTimers() should only be called by HookLaunchSequence()
 */
void CreateOvertimeReminderTimers() {
	if ( INVALID_HANDLE != g_Timer_RoundStartOverTimeReminders )
		KillTimer(g_Timer_RoundStartOverTimeReminders);
	
	g_Timer_RoundStartOverTimeReminders =  CreateTimer( 1.0, Timer_RoundStartOvertimeReminders, TIMER_FLAG_NO_MAPCHANGE );
}

Action Timer_RoundStartOvertimeReminders( Handle timer ) {
	float fRoundTimeElapsed = SDKCall( g_hGetRoundTimeElapsed );
	if ( 1 <= FloatCompare( 10.0, fRoundTimeElapsed ) ) {
		g_Timer_RoundStartOverTimeReminders = INVALID_HANDLE;
		CreateOvertimeReminderTimers();
		return Plugin_Stop;
	}
	
	g_Timer_RoundStartOverTimeReminders = INVALID_HANDLE;
	
	PrintToChatAll(
		"%s",
		g_sPunksShouldLaunch
	);
	
	float fRoundTimeLeft = SDKCall( g_hGetRoundTimeLeft );
	if ( 1 <= FloatCompare( 120.0, fRoundTimeLeft ) )
		return Plugin_Stop;
	
	/* these have to be three separate functions since we cannot pass the global variables by reference in sourcepawn */
	g_Timer_OvertimeReminder120 = CreateTimer( (fRoundTimeLeft - 120.0), Timer_OvertimeReminder120, TIMER_FLAG_NO_MAPCHANGE );
	g_Timer_OvertimeReminder90 = CreateTimer( (fRoundTimeLeft - 90.0), Timer_OvertimeReminder90, TIMER_FLAG_NO_MAPCHANGE );
	g_Timer_OvertimeReminder60 = CreateTimer( (fRoundTimeLeft - 62.0), Timer_OvertimeReminder60, TIMER_FLAG_NO_MAPCHANGE  );
	
	return Plugin_Stop;
}

Action Timer_OvertimeReminder120( Handle timer ) {
	PrintToChatAll(
		"%s",
		g_sPunksShouldLaunch
	);
	g_Timer_OvertimeReminder120 = INVALID_HANDLE;
	return Plugin_Stop;
}

Action Timer_OvertimeReminder90 ( Handle timer ) {
	PrintToChatAll(
		"%s",
		g_sPunksShouldLaunch
	);
	g_Timer_OvertimeReminder90 = INVALID_HANDLE;
	return Plugin_Stop;
}

Action Timer_OvertimeReminder60( Handle timer ) {
	PrintToChatAll(
		"%s",
		g_sPunksShouldLaunch
	);
	g_Timer_OvertimeReminder60 = INVALID_HANDLE;
	return Plugin_Stop;
}

Action CountdownBegin ( const char[] output, int caller, int activator, float delay ) {
	if ( !g_bFullyHooked )
		return;
	
	// if more than 60 seconds left, return;
	float fCurtime = view_as<float>(ReadInt(Transpose( gpGlobals, g_iCurtimeOffset )));
	float fRoundEndTime = view_as<float>(ReadInt(Transpose( g_pGameRules, g_iRoundEndTimeOffset )));
	
	if ( 0 <= FloatCompare( (fRoundEndTime - fCurtime), g_fTimerDelta ) && !g_bDebugMode )
		return;
	
	g_bCountdownBonusTime = true;
	
	// add a minute
	fRoundEndTime += g_fTimerDelta;
	StoreToAddress( Transpose( g_pGameRules, g_iRoundEndTimeOffset ), view_as<int>(fRoundEndTime), NumberType_Int32 );
	
	// update the round length
	float fRoundTimeLimit = view_as<float>(ReadInt( g_pRoundTimeLimit ));
	fRoundTimeLimit += g_fTimerDelta;
	StoreToAddress( g_pRoundTimeLimit, view_as<int>(fRoundTimeLimit), NumberType_Int32 );
	
	SDKCall(g_hNotifyNetworkStateChanged);
	
	PrintToChatAll( "%s", g_sOvertimeActive );
}

Action CountdownAbort ( const char[] output, int caller, int activator, float delay ) {
	if ( !g_bFullyHooked || !g_bCountdownBonusTime )
		return;
	
	g_bCountdownBonusTime = false;
	
	// subtract a minute
	float fRoundEndTime = view_as<float>(ReadInt(Transpose( g_pGameRules, g_iRoundEndTimeOffset )));
	fRoundEndTime -= g_fTimerDelta;
	StoreToAddress( Transpose( g_pGameRules, g_iRoundEndTimeOffset ), view_as<int>(fRoundEndTime), NumberType_Int32 );
	
	// return normal round time
	float fRoundTimeLimit = view_as<float>(ReadInt( g_pRoundTimeLimit ));
	fRoundTimeLimit -= g_fTimerDelta;
	StoreToAddress( g_pRoundTimeLimit, view_as<int>(fRoundTimeLimit), NumberType_Int32 );
	
	SDKCall(g_hNotifyNetworkStateChanged);
}

Action LaunchResult ( const char[] output, int caller, int activator, float delay ) {
	if ( !g_bFullyHooked || !g_bCountdownBonusTime )
		return;
	
	g_bCountdownBonusTime = false;
	
	KillOvertimeReminderTimers();
	
	// return normal round time
	float fRoundTimeLimit = view_as<float>(ReadInt( g_pRoundTimeLimit ));
	fRoundTimeLimit -= g_fTimerDelta;
	StoreToAddress( g_pRoundTimeLimit, view_as<int>(fRoundTimeLimit), NumberType_Int32 );
}

