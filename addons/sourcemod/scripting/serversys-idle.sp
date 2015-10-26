#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <smlib>

#include <serversys>

#undef REQUIRE_EXTENSIONS
#include <cstrike>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo = {
	name = "[Server-Sys] Idle Server",
	description = "Server-Sys idle server handler.",
	author = "cam",
	version = SERVERSYS_VERSION,
	url = SERVERSYS_URL
}

int g_iServerStart;
int g_iLastMapChange;

bool g_bWelcome;
char g_cWelcomeTitle[64];
char g_cWelcomeText[256];

bool g_bOverrideSpawn;
bool g_bDisableButtons;
bool g_bDisableMovement;
bool g_bUpTime;
bool g_bAutoPick;
bool g_bDisableSounds;
char g_cMap[64];
char g_cUptimeCommand[128];

bool g_bLateLoad = false;
bool g_bAwayKill = false;

int g_iAwayTimeout;

float g_fSpawn_Away[3];
float g_fSpawn_Active[3];

bool g_bSpawned[MAXPLAYERS+1];

int g_iLastMovement[MAXPLAYERS+1];
int g_iLastButtons[MAXPLAYERS+1];

int  g_iAwayTeam = 2;
int  g_iAwayTeam_Default;

public void OnPluginStart(){
	g_iServerStart = GetTime();

	LoadConfig();

	LoadTranslations("common.phrases");
	LoadTranslations("generic.phrases");
	LoadTranslations("serversys.idle.phrases");

	HookEvent("player_connect_full", Event_OnFullConnect, EventHookMode_Pre);
	HookEvent("cs_match_end_restart", Event_OnMatchRestart, EventHookMode_Pre);
	HookEvent("round_start", Event_RoundStart, EventHookMode_Pre);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_Pre);
	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);

	AddNormalSoundHook(Hook_Sound);

	if(g_bLateLoad && PlayerCount() > 0){
		PrintTextChatAll("%t", "Live updates");
	}
}

public void OnAllPluginsLoaded(){
	Sys_RegisterChatCommand(g_cUptimeCommand, Command_Uptime);
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max){
	g_bLateLoad = late;

	return APLRes_Success;
}

public void OnClientPutInServer(int client){
	g_bSpawned[client] = false;
	g_iLastMovement[client] = GetTime();

	SDKHook(client, SDKHook_SetTransmit, Hook_SetTransmit);
}

public void OnClientDisconnect(int client){
	SDKUnhook(client, SDKHook_SetTransmit, Hook_SetTransmit);
}

public void OnMapStart(){
	g_iLastMapChange = GetTime();
	GetCurrentMap(g_cMap, sizeof(g_cMap));
	ServerCommand("sm_cvar nextlevel %s", g_cMap);
}

public void OnMapEnd(){
	if(g_iAwayTeam_Default == 0){
		g_iAwayTeam = GetRandomInt(2,3);
	}else{
		g_iAwayTeam = g_iAwayTeam_Default;
	}
}

void LoadConfig(){
	Handle kv = CreateKeyValues("Idle");
	char Config_Path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, Config_Path, sizeof(Config_Path), "configs/serversys/idle.cfg");

	if(!(FileExists(Config_Path)) || !(FileToKeyValues(kv, Config_Path))){
		Sys_KillHandle(kv);
		SetFailState("[serversys] idle :: Cannot read from configuration file: %s", Config_Path);
	}

	if(KvJumpToKey(kv, "welcome")){
		g_bWelcome = view_as<bool>(KvGetNum(kv, "enabled", 1));

		KvSetEscapeSequences(kv, true);
		KvGetString(kv, "title", g_cWelcomeTitle, sizeof(g_cWelcomeTitle), "Idle Server");
		KvGetString(kv, "message", g_cWelcomeText, sizeof(g_cWelcomeText), "Thanks for choosing us!");
		KvSetEscapeSequences(kv, false);

		KvGoBack(kv);
	}

	if(KvJumpToKey(kv, "farming")){
		g_bAwayKill = view_as<bool>(KvGetNum(kv, "enabled", 0));
		g_iAwayTimeout = KvGetNum(kv, "away-timeout", 30);
		g_iAwayTeam_Default = KvGetNum(kv, "away-team", 0);

		if(g_iAwayTeam_Default == 0)
			g_iAwayTeam = GetRandomInt(2,3);
		else
			g_iAwayTeam = g_iAwayTeam_Default;

		if(KvJumpToKey(kv, "spawns")){
			g_bOverrideSpawn = true;

			g_fSpawn_Away[0] = KvGetFloat(kv, "away-x", 0.0);
			g_fSpawn_Away[1] = KvGetFloat(kv, "away-y", 0.0);
			g_fSpawn_Away[2] = KvGetFloat(kv, "away-z", 0.0);

			g_fSpawn_Active[0] = KvGetFloat(kv, "active-x", 0.0);
			g_fSpawn_Active[1] = KvGetFloat(kv, "active-y", 0.0);
			g_fSpawn_Active[2] = KvGetFloat(kv, "active-z", 0.0);

			KvGoBack(kv);
		}else g_bOverrideSpawn = false;

		KvGoBack(kv);
	}else
		g_bAwayKill = false;

	if(KvJumpToKey(kv, "misc")){
		g_bDisableMovement  = view_as<bool>(KvGetNum(kv, "disable-movement", 0));
		g_bDisableButtons 	= view_as<bool>(KvGetNum(kv, "disable-buttons", 1));
		g_bDisableSounds 	= view_as<bool>(KvGetNum(kv, "disable-sounds", 0));
		g_bAutoPick 		= view_as<bool>(KvGetNum(kv, "auto-assign", 1));

		KvGoBack(kv);
	}

	if(KvJumpToKey(kv, "uptime")){
		g_bUpTime = view_as<bool>(KvGetNum(kv, "enabled", 0));
		KvGetString(kv, "command", g_cUptimeCommand, sizeof(g_cUptimeCommand), "uptime");

		KvGoBack(kv);
	}

	Sys_KillHandle(kv);
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3]){
	// if(IsClientInGame(client) && IsPlayerAlive(client)){
	// 	if(g_bDisableButtons){
	// 		buttons &= ~IN_JUMP;
	// 		buttons &= ~IN_ATTACK;
	// 		buttons &= ~IN_ATTACK2;
	// 		buttons &= ~IN_FORWARD;
	// 		buttons &= ~IN_BACK;
	// 		buttons &= ~IN_MOVELEFT;
	// 		buttons &= ~IN_MOVERIGHT;
	// 		buttons &= ~IN_RIGHT;
	// 		buttons &= ~IN_LEFT;
	// 	}else{
	// 		if(g_bAwayKill){
	// 			if(g_iLastButtons[client] != buttons){
	// 				g_iLastMovement[client] = GetTime();
	// 				g_iLastButtons[client] = buttons;
	//
	// 				if(GetClientTeam(client) == g_iAwayTeam){
	// 					ChangeClientTeam(client, (g_iAwayTeam == 2 ? 3 : 2));
	// 					ForcePlayerSuicide(client);
	// 					CS_RespawnPlayer(client);
	//
	// 					PrintTextChat(client, "%t", "Swapped because back");
	// 				}
	// 			}else{
	// 				if((GetTime() - g_iLastMovement[client] > g_iAwayTimeout) && GetClientTeam(client) != g_iAwayTeam){
	// 					ChangeClientTeam(client, g_iAwayTeam);
	// 					ForcePlayerSuicide(client);
	// 					CS_RespawnPlayer(client);
	//
	// 					PrintTextChat(client, "%t", "Swapped because away");
	// 				}
	// 			}
	// 		}
	// 	}
	// }

	return Plugin_Continue;
}

public Action Hook_Sound(int clients[64], int &numc, char sam[PLATFORM_MAX_PATH], int &ent, int &ch, float &vo, int &lv, int &pi, int &fl){
	if(!g_bDisableSounds)
		return Plugin_Continue;

	if((0 < ent <= MaxClients) && IsClientInGame(ent))
		return Plugin_Handled;

	return Plugin_Continue;
}

public Action Hook_SetTransmit(int entity, int client){
	if((0 < client <= MaxClients) && (0 < entity <= MaxClients) && IsClientInGame(client) && IsClientInGame(entity)){
		if(!g_bAwayKill)
			return Plugin_Handled;

		if(GetClientTeam(client) == g_iAwayTeam || (GetClientTeam(client) == GetClientTeam(entity)))
			return Plugin_Handled;
	}

	return Plugin_Continue;
}

public void Command_Uptime(int client, const char[] command, const char[] args){
	if(g_bUpTime && (0 < client <= MaxClients) && IsClientInGame(client)){
		float time = GetEngineTime() - g_iServerStart;
		int hours = RoundToFloor(time/3600.0);
		time -= hours*3600.0;
		int minutes = RoundToFloor(time/60.0);
		time -= hours*60.0;
		PrintTextChat(client, "%t", "Idle uptime", hours, minutes, time);
	}
}

public Action Event_PlayerSpawn(Handle event, const char[] name, bool dontBroadcast){
	int client = GetClientOfUserId(GetEventInt(event, "userid"));

	if(0 < client <= MaxClients && IsClientInGame(client)){
		if(g_bDisableMovement){
			SetEntPropFloat(client, Prop_Data, "m_flLaggedMovementValue", 0.0);
		}

		//CreateTimer(0.25, PlayerSpawnPost, GetClientUserId(client));
	}
}

// public Action PlayerSpawnPost(Handle timer, int userid){
// 	int client = GetClientOfUserId(userid);
//
// 	// if(0 < client <= MaxClients && IsClientInGame(client)){
// 	// 	//CS_RespawnPlayer(client);
// 	// 	if(g_bAwayKill == true && SpawnSetup() == true){
// 	// 		float destination[3];
// 	// 		if(GetClientTeam(client) == g_iAwayTeam)
// 	// 			destination = g_fSpawn_Away;
// 	// 		else
// 	// 			destination = g_fSpawn_Active;
// 	//
// 	// 		TeleportEntity(client, destination, NULL_VECTOR, NULL_VECTOR);
// 	// 		PrintTextChatAll("Teleporting client to %f %f %f", destination[0], destination[1], destination[2]);
// 	// 	}
// 	// }
//
// 	return Plugin_Stop;
// }

public Action WelcomeMenuTimer(Handle timer, int userid){
	int client = GetClientOfUserId(userid);

	if(0 < client <= MaxClients && IsClientInGame(client)){
		// Menu WelcomeMenu = CreateMenu(Menu_Welcome_Handler);
		// WelcomeMenu.SetTitle(g_cWelcomeTitle);
		//
		// WelcomeMenu.AddItem("spacer", " ", ITEMDRAW_SPACER);
		// WelcomeMenu.AddItem("desc", g_cWelcomeText, ITEMDRAW_RAWLINE);
		//
		// WelcomeMenu.Display(client, 30);
	}

	return Plugin_Stop;
}

public int Menu_Welcome_Handler(Menu menu, MenuAction action, int param1, int param2){
	if(action == MenuAction_End){
		delete menu;
	}
}

public Action Event_RoundStart(Handle event, const char[] name, bool dontBroadcast){
	ServerCommand("sm_cvar mp_default_team_winner_no_objective %d", (g_iAwayTeam == 2 ? 3 : 2));
	ServerCommand("mp_warmup_end");
	return Plugin_Continue;
}

public Action Event_RoundEnd(Handle event, const char[] name, bool dontBroadcast){
	for(int client = 1; client <= MaxClients; client++){
		if(IsClientInGame(client))
			ForcePlayerSuicide(client);
	}
	PrintTextChatAll("%t", "Map wrap up");
	if((GetTime() - g_iLastMapChange) > 60*7){
		ServerCommand("sm_map %s", g_cMap);
	}
	return Plugin_Continue;
}

public Action Event_OnFullConnect(Handle event, const char[] name, bool dontBroadcast){
	if(g_bAutoPick){
		int client = GetClientOfUserId(GetEventInt(event, "userid"));

		if(!client || client == 0 || !IsClientInGame(client))
			return Plugin_Continue;

		ChangeClientTeam(client, g_iAwayTeam);
		ForcePlayerSuicide(client);
		CS_RespawnPlayer(client);

		if(g_bWelcome == true && g_bSpawned[client] == false){
			g_bSpawned[client] = true;
			CreateTimer(5.0, WelcomeMenuTimer, GetClientUserId(client));
		}
	}

	return Plugin_Continue;
}

public Action Event_OnMatchRestart(Handle event, const char[] name, bool dontBroadcast){
	if(g_bAutoPick){
		for(int client = 1; client <= MaxClients; client++){
			if(!IsClientInGame(client))
				continue;

			if(g_bAwayKill)
				ChangeClientTeam(client, g_iAwayTeam);
			else
				ChangeClientTeam(client, PickTeam());
		}
	}

	return Plugin_Continue;
}

stock bool SpawnSetup(){
	if(!g_bOverrideSpawn)
		return false;

	if(g_fSpawn_Away[0] != 0.0)
		return true;
	if(g_fSpawn_Away[1] != 0.0)
		return true;
	if(g_fSpawn_Away[2] != 0.0)
		return true;
	if(g_fSpawn_Active[0] != 0.0)
		return true;
	if(g_fSpawn_Active[1] != 0.0)
		return true;
	if(g_fSpawn_Active[2] != 0.0)
		return true;

	return false;
}

stock int PlayerCount(){
	int count = 0;
	for(int i=1;i<=MaxClients;i++){
		if(IsClientInGame(i))
			count++;
	}

	return count;
}

stock int PickTeam(){
	int blu = 0; int red = 0;
	for(int i=1;i<=MaxClients;i++){
		if(IsClientInGame(i)){
			if(GetClientTeam(i) == 2)
				red++;
			if(GetClientTeam(i) == 3)
				blu++;
		}
	}

	if(red > blu)
		return 3;

	return 2;
}
