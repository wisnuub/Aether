/*
 * Copyright (C) 2026 Aether contributors
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * Aether SteamBridge: Steam Cloud saves and achievements for the native
 * Plants vs. Zombies GOTY runtime (Steam app 3590).
 *
 * Behaves like the Steam Windows build:
 *  - users.dat and user<N>.dat are stored at the Steam Cloud root under the
 *    same names, so progress moves between this runtime and the Windows game.
 *  - Achievements use the app's own Steam API names.
 *
 * libsteam_api is loaded at runtime from the executable's directory, so no
 * Steamworks SDK headers are needed to build. Built without AETHER_STEAM,
 * every function is an inline no-op.
 */

#ifndef AETHER_STEAM_BRIDGE_H
#define AETHER_STEAM_BRIDGE_H

#include <cstddef>
#include <string>

namespace SteamBridge
{
#ifdef AETHER_STEAM
	// When not started by Steam, ask Steam to launch app 3590 and return true;
	// the caller should then exit. Launching through Steam is what makes Steam
	// download cloud saves before the game and upload them afterwards.
	bool RestartThroughSteamIfNeeded();

	// Connect to Steam. Returns false when Steam is unavailable; every other
	// call is then a no-op.
	bool Init();
	void Shutdown();
	bool IsActive();
	void RunCallbacks();

	// Two-way reconcile of users.dat / user<N>.dat between theUserDataDir and
	// Steam Cloud by modification time. A local file replaced by a newer cloud
	// copy is kept in theUserDataDir/cloud-backup/.
	void SyncCloudSaves(const std::string& theUserDataDir);

	// Write one save file to Steam Cloud (after writing it locally).
	void PushCloudFile(const std::string& theName, const void* theData, size_t theLen);
	void DeleteCloudFile(const std::string& theName);

	// theAchievement is the game's AchievementId (0..19).
	void UnlockAchievement(int theAchievement);
	// Report every achievement already earned in a profile (never clears any).
	void SyncEarnedAchievements(const bool* theEarned, int theCount);
	void UnlockAchievementByApiName(const char* theApiName);
#else
	inline bool RestartThroughSteamIfNeeded() { return false; }
	inline bool Init() { return false; }
	inline void Shutdown() {}
	inline bool IsActive() { return false; }
	inline void RunCallbacks() {}
	inline void SyncCloudSaves(const std::string&) {}
	inline void PushCloudFile(const std::string&, const void*, size_t) {}
	inline void DeleteCloudFile(const std::string&) {}
	inline void UnlockAchievement(int) {}
	inline void SyncEarnedAchievements(const bool*, int) {}
	inline void UnlockAchievementByApiName(const char*) {}
#endif
}

#endif
