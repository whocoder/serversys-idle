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

bool g_bWelcome;
char g_cWelcomeTitle[128];
char g_cWelcomeText[1024];

bool g_bOverrideSpawn;
bool g_bDisableButtons;
bool g_bDisableMovement;
bool g_bUpTime;
bool g_bAutoPick;
bool g_bDisableSounds;
char g_cMap[128];
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

bool g_bIdling = false;

ConVar cv_RoundTime;
ConVar cv_DefaultWin;
ConVar cv_IgnoreWins;
ConVar cv_DoWarmUp;
ConVar cv_NextLevel;

public void OnPluginStart(){
	g_iServerStart = GetTime();

	LoadConfig();

	LoadTranslations("common.phrases");
	LoadTranslations("generic.phrases");
	LoadTranslations("serversys.idle.phrases");

	HookEvent("player_connect_full", Event_OnFullConnect, EventHookMode_Post);
	HookEvent("cs_match_end_restart", Event_OnMatchRestart, EventHookMode_Post);
	HookEvent("round_start", Event_RoundStart, EventHookMode_Post);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
	HookEvent("player_team", Event_PlayerTeam, EventHookMode_Pre);

	AddNormalSoundHook(Hook_Sound);

	if(g_bLateLoad && PlayerCount() > 0){
		CPrintToChatAll("%t", "Live updates");
	}

	cv_RoundTime = FindConVar("mp_roundtime");
	cv_IgnoreWins = FindConVar("mp_ignore_round_win_conditions");
	cv_DefaultWin = FindConVar("mp_default_team_winner_no_objective");
	cv_DoWarmUp = FindConVar("mp_do_warmup_period");
	cv_NextLevel = FindConVar("nextlevel");

	cv_RoundTime.IntValue = 5;
	cv_IgnoreWins.IntValue = 1;
	cv_DoWarmUp.IntValue = 0;

	cv_DoWarmUp.AddChangeHook(Hook_ConVarChanged);
	cv_IgnoreWins.AddChangeHook(Hook_ConVarChanged);
	cv_RoundTime.AddChangeHook(Hook_ConVarChanged);
}

public void Hook_ConVarChanged(ConVar cv, const char[] value1, const char[] value2){
	if(!StrEqual(value1, value2, false)){
		if(cv == cv_DoWarmUp)
			cv_DoWarmUp.IntValue = 0;

		if(cv == cv_RoundTime)
			cv_RoundTime.IntValue = 5;

		if(cv == cv_NextLevel)
			cv_NextLevel.SetString(g_cMap, true, false);
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
	cv_IgnoreWins.IntValue = 1;
	cv_RoundTime.FloatValue = 5.0;

	GetCurrentMap(g_cMap, sizeof(g_cMap));
	cv_NextLevel.SetString(g_cMap, true, false);
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
		g_iAwayTimeout = KvGetNum(kv, "away_timeout", 30);
		g_iAwayTeam_Default = KvGetNum(kv, "away_team", 0);

		if(g_iAwayTeam_Default == 0)
			g_iAwayTeam = GetRandomInt(2,3);
		else
			g_iAwayTeam = g_iAwayTeam_Default;

		if(KvJumpToKey(kv, "spawns")){
			g_bOverrideSpawn = true;

			g_fSpawn_Away[0] = KvGetFloat(kv, "away_x", 0.0);
			g_fSpawn_Away[1] = KvGetFloat(kv, "away_y", 0.0);
			g_fSpawn_Away[2] = KvGetFloat(kv, "away_z", 0.0);

			g_fSpawn_Active[0] = KvGetFloat(kv, "active_x", 0.0);
			g_fSpawn_Active[1] = KvGetFloat(kv, "active_y", 0.0);
			g_fSpawn_Active[2] = KvGetFloat(kv, "active_z", 0.0);

			KvGoBack(kv);
		}else g_bOverrideSpawn = false;

		KvGoBack(kv);
	}else
		g_bAwayKill = false;

	if(KvJumpToKey(kv, "misc")){
		g_bDisableMovement  = view_as<bool>(KvGetNum(kv, "disable_movement", 0));
		g_bDisableButtons 	= view_as<bool>(KvGetNum(kv, "disable_buttons", 0));
		g_bDisableSounds 	= view_as<bool>(KvGetNum(kv, "disable_sounds", 0));
		g_bAutoPick 		= view_as<bool>(KvGetNum(kv, "auto_assign", 0));

		KvGoBack(kv);
	}else{
		g_bDisableMovement = false;
		g_bDisableButtons = false;
		g_bDisableSounds = false;
		g_bAutoPick = false;
	}

	if(KvJumpToKey(kv, "uptime")){
		g_bUpTime = view_as<bool>(KvGetNum(kv, "enabled", 0));
		KvGetString(kv, "command", g_cUptimeCommand, sizeof(g_cUptimeCommand), "uptime");

		KvGoBack(kv);
	}

	Sys_KillHandle(kv);
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3]){
	if(IsClientInGame(client) && IsPlayerAlive(client)){
		if(g_bDisableButtons == true){
			buttons &= ~IN_JUMP;
			buttons &= ~IN_ATTACK;
			buttons &= ~IN_ATTACK2;
			buttons &= ~IN_FORWARD;
			buttons &= ~IN_BACK;
			buttons &= ~IN_MOVELEFT;
			buttons &= ~IN_MOVERIGHT;
			buttons &= ~IN_RIGHT;
			buttons &= ~IN_LEFT;
			buttons &= ~IN_DUCK;
		}

		// This bit is so that players can still
		//	use the scoreboard without being swapped.
		int ourbuttons = buttons;
		ourbuttons &= ~IN_SCORE;

		if(g_bAwayKill){
			if(g_iLastButtons[client] != ourbuttons){
				g_iLastMovement[client] = GetTime();
				g_iLastButtons[client] = ourbuttons;

				if(GetClientTeam(client) == g_iAwayTeam){
					ChangeClientTeam(client, (g_iAwayTeam == 2 ? 3 : 2));
					ForcePlayerSuicide(client);
					CS_RespawnPlayer(client);

					CPrintToChat(client, "%t", "Swapped because back");
				}
			}else if(((GetTime() - g_iLastMovement[client]) > g_iAwayTimeout) && (GetClientTeam(client) != g_iAwayTeam)){
				ChangeClientTeam(client, g_iAwayTeam);
				ForcePlayerSuicide(client);
				CS_RespawnPlayer(client);

				CPrintToChat(client, "%t", "Swapped because away");
			}
		}
	}

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
	if(entity != client && (0 < client <= MaxClients) && (0 < entity <= MaxClients) && IsClientInGame(client) && IsClientInGame(entity)){
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
		CPrintToChat(client, "%t", "Idle uptime", hours, minutes, time);
	}
}

public Action Event_PlayerSpawn(Handle event, const char[] name, bool dontBroadcast){
	int client = GetClientOfUserId(GetEventInt(event, "userid"));

	if(0 < client <= MaxClients && IsClientInGame(client)){
		if(g_bDisableMovement){
			SetEntPropFloat(client, Prop_Data, "m_flLaggedMovementValue", 0.0);
		}

		if(g_bAwayKill){
			CreateTimer(0.0, PlayerSpawnPost, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
		}
	}

	cv_RoundTime.FloatValue = 5.0;
	cv_IgnoreWins.IntValue = 1;

	if(!g_bIdling){
		CreateTimer((cv_RoundTime.FloatValue*60.0), Timer_EndRound, _, TIMER_FLAG_NO_MAPCHANGE);
		g_bIdling = true;
	}

	return Plugin_Continue;
}

public Action Event_PlayerTeam(Handle event, const char[] name, bool dontBroadcast){
	int client = GetClientOfUserId(GetEventInt(event, "userid"));

	if((0 < client <= MaxClients) && IsClientInGame(client) && !IsPlayerAlive(client)){
		CreateTimer(0.1, Timer_Respawn, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}

	dontBroadcast = true;
	return Plugin_Changed;
}

public Action Event_PlayerDeath(Handle event, const char[] name, bool dontBroadcast){
	dontBroadcast = true;
	return Plugin_Changed;
}


public Action Timer_Respawn(Handle timer, int userid){
	int client = GetClientOfUserId(userid);

	if((0 < client <= MaxClients) && IsClientInGame(client) && !IsPlayerAlive(client)){
		if(GetClientTeam(client) == 2 || GetClientTeam(client) == 3){
			CS_RespawnPlayer(client);
		}
	}

	return Plugin_Stop;
}

public Action Timer_EndRound(Handle timer, any data){
	cv_IgnoreWins.IntValue = 0;

	CPrintToChatAll("%t", "Forcing round end");
	CPrintToChatAll("%t", "Teams will be randomized");
	CS_TerminateRound(5.0, CSRoundEnd_Draw, false);

	return Plugin_Stop;
}

public Action Timer_EndMap(Handle timer, any data){
	ServerCommand("sm_map %s", g_cMap);

	return Plugin_Stop;
}

public Action PlayerSpawnPost(Handle timer, int userid){
	int client = GetClientOfUserId(userid);

	if((0 < client <= MaxClients) && IsClientInGame(client)){
		if(g_bAwayKill == true && SpawnSetup() == true){
			TeleportEntity(client, ((GetClientTeam(client) == g_iAwayTeam) ? g_fSpawn_Away : g_fSpawn_Active), NULL_VECTOR, NULL_VECTOR);
			PrintToServer("Spawning client %N at %f, %f, %f,", client,
				((GetClientTeam(client) == g_iAwayTeam) ? g_fSpawn_Away[0] : g_fSpawn_Active[0]),
				((GetClientTeam(client) == g_iAwayTeam) ? g_fSpawn_Away[1] : g_fSpawn_Active[1]),
				((GetClientTeam(client) == g_iAwayTeam) ? g_fSpawn_Away[2] : g_fSpawn_Active[2]));
		}
	}

	return Plugin_Stop;
}

public Action WelcomeMenuTimer(Handle timer, int userid){
	int client = GetClientOfUserId(userid);

	if(0 < client <= MaxClients && IsClientInGame(client)){
		Menu WelcomeMenu = CreateMenu(Menu_Welcome_Handler);
		WelcomeMenu.SetTitle(g_cWelcomeTitle);

		char therest[1024];
		Format(therest, sizeof(therest), "\n\n%s", g_cWelcomeText);

		WelcomeMenu.AddItem("mainmessage", g_cWelcomeText, ITEMDRAW_DISABLED);

		WelcomeMenu.Display(client, 30);
	}

	return Plugin_Stop;
}

public int Menu_Welcome_Handler(Menu menu, MenuAction action, int param1, int param2){
	if(action == MenuAction_End){
		delete menu;
	}
}

public Action Event_RoundStart(Handle event, const char[] name, bool dontBroadcast){
	if(g_bAwayKill)
		cv_DefaultWin.IntValue = (g_iAwayTeam == 2 ? 3 : 2);
	else
		cv_DefaultWin.IntValue = (GetRandomInt(2,3));

	cv_RoundTime.FloatValue = 5.0;
	cv_IgnoreWins.IntValue = 1;

	if(!g_bIdling){
		CreateTimer((cv_RoundTime.FloatValue*60.0), Timer_EndRound, _, TIMER_FLAG_NO_MAPCHANGE);
		g_bIdling = true;
	}

	return Plugin_Continue;
}

public Action CS_OnTerminateRound(float &delay, CSRoundEndReason &reason){
	g_bIdling = false;

	if(g_bAwayKill && (reason == CSRoundEnd_Draw)){
		switch(g_iAwayTeam){
			case 2:{
				reason = CSRoundEnd_CTWin;
			}
			case 3:{
				reason = CSRoundEnd_TerroristWin;
			}
		}
	}

	for(int client = 1; client <= MaxClients; client++){
		if(IsClientInGame(client) && IsPlayerAlive(client)){
			ForcePlayerSuicide(client);
			CPrintToChat(client, "%t", "Map wrap up");
		}
	}

	return Plugin_Continue;
}

public Action Event_OnFullConnect(Handle event, const char[] name, bool dontBroadcast){
	if(g_bAutoPick){
		int client = GetClientOfUserId(GetEventInt(event, "userid"));

		if(!client || client == 0 || !IsClientInGame(client))
			return Plugin_Continue;

		SetEntProp(client, Prop_Send, "m_lifeState", 0);

		SetEntProp(client, Prop_Send, "m_iTeamNum", PickTeam());
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

			ChangeClientTeam(client, PickTeam());

			if(IsPlayerAlive(client)){
				ForcePlayerSuicide(client);
				CS_RespawnPlayer(client);
			}
		}
	}

	return Plugin_Continue;
}

stock bool SpawnSetup(){
	if(!g_bAwayKill)
		return false;

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
	if(g_bAwayKill == true)
		return g_iAwayTeam;

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
