{- git-annex command
 -
 - Copyright 2011 Joey Hess <joey@kitenet.net>
 - Copyright 2011 Joachim Breitner <mail@joachim-breitner.de>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE BangPatterns #-}

module Command.Sync where

import Common.Annex
import Command
import qualified Remote
import qualified Annex
import qualified Annex.Branch
import qualified Git.Command
import qualified Git.Branch
import qualified Git.Config
import qualified Git.Ref
import qualified Git
import qualified Types.Remote

import qualified Data.ByteString.Lazy.Char8 as L
import qualified Data.Map as M

def :: [Command]
def = [command "sync" (paramOptional (paramRepeating paramRemote))
	[seek] "synchronize local repository with remotes"]

-- syncing involves several operations, any of which can independently fail
seek :: CommandSeek
seek rs = do
	!branch <- currentBranch
	remotes <- syncRemotes rs
	return $ concat $
		[ [ commit ]
		, [ mergeLocal branch ]
		, [ pullRemote remote branch | remote <- remotes ]
		, [ mergeAnnex ]
		, [ pushLocal branch ]
		, [ pushRemote remote branch | remote <- remotes ]
		]

syncBranch :: Git.Ref -> Git.Ref
syncBranch = Git.Ref.under "refs/heads/synced/"

remoteBranch :: Remote.Remote Annex -> Git.Ref -> Git.Ref
remoteBranch remote = Git.Ref.under $ "refs/remotes/" ++ Remote.name remote

syncRemotes :: [String] -> Annex [Remote.Remote Annex]
syncRemotes rs = do
	fast <- Annex.getState Annex.fast
	if fast
		then nub <$> pickfast
		else wanted
	where
		pickfast = (++) <$> listed <*> (fastest <$> available)
		wanted
			| null rs = available
			| otherwise = listed
		listed = mapM Remote.byName rs
		available = filterM hasurl =<< Remote.enabledRemoteList
		hasurl r = not . null <$> geturl r
		geturl r = fromRepo $ Git.Config.get ("remote." ++ Remote.name r ++ ".url") ""
		fastest = fromMaybe [] . headMaybe .
			map snd . sort . M.toList . costmap
		costmap = M.fromListWith (++) . map costpair
		costpair r = (Types.Remote.cost r, [r])

commit :: CommandStart
commit = do
	showStart "commit" ""
	next $ next $ do
		showOutput
		-- Commit will fail when the tree is clean, so ignore failure.
		_ <- inRepo $ Git.Command.runBool "commit"
			[Param "-a", Param "-m", Param "git-annex automatic sync"]
		return True

mergeLocal :: Git.Ref -> CommandStart
mergeLocal branch = go =<< needmerge
	where
		syncbranch = syncBranch branch
		needmerge = do
			unlessM (inRepo $ Git.Ref.exists syncbranch) $
				updateBranch syncbranch
			inRepo $ Git.Branch.changed branch syncbranch
		go False = stop
		go True = do
			showStart "merge" $ Git.Ref.describe syncbranch
			next $ next $ mergeFrom syncbranch

pushLocal :: Git.Ref -> CommandStart
pushLocal branch = do
	updateBranch $ syncBranch branch
	stop

updateBranch :: Git.Ref -> Annex ()
updateBranch syncbranch = 
	unlessM go $ error $ "failed to update " ++ show syncbranch
	where
		go = inRepo $ Git.Command.runBool "branch"
			[ Param "-f"
			, Param $ show $ Git.Ref.base syncbranch
			]

pullRemote :: Remote.Remote Annex -> Git.Ref -> CommandStart
pullRemote remote branch = do
	showStart "pull" (Remote.name remote)
	next $ do
		showOutput
		fetched <- inRepo $ Git.Command.runBool "fetch"
			[Param $ Remote.name remote]
		if fetched
			then next $ mergeRemote remote branch
			else stop

{- The remote probably has both a master and a synced/master branch.
 - Which to merge from? Well, the master has whatever latest changes
 - were committed, while the synced/master may have changes that some
 - other remote synced to this remote. So, merge them both. -}
mergeRemote :: Remote.Remote Annex -> Git.Ref -> CommandCleanup
mergeRemote remote branch = all id <$> (mapM merge =<< tomerge)
	where
		merge = mergeFrom . remoteBranch remote
		tomerge = filterM (changed remote) [branch, syncBranch branch]

pushRemote :: Remote.Remote Annex -> Git.Ref -> CommandStart
pushRemote remote branch = go =<< needpush
	where
		needpush = anyM (newer remote) [syncbranch, Annex.Branch.name]
		go False = stop
		go True = do
			showStart "push" (Remote.name remote)
			next $ next $ do
				showOutput
				inRepo $ Git.Command.runBool "push" $
					[ Param (Remote.name remote)
					, Param (show $ Annex.Branch.name)
					, Param refspec
					]
		refspec = show (Git.Ref.base branch) ++ ":" ++ show (Git.Ref.base syncbranch)
		syncbranch = syncBranch branch

mergeAnnex :: CommandStart
mergeAnnex = do
	Annex.Branch.forceUpdate
	stop

currentBranch :: Annex Git.Ref
currentBranch = Git.Ref . firstLine . L.unpack <$>
	inRepo (Git.Command.pipeRead [Param "symbolic-ref", Param "HEAD"])

mergeFrom :: Git.Ref -> CommandCleanup
mergeFrom branch = do
	showOutput
	inRepo $ Git.Command.runBool "merge" [Param $ show branch]

changed :: Remote.Remote Annex -> Git.Ref -> Annex Bool
changed remote b = do
	let r = remoteBranch remote b
	e <- inRepo $ Git.Ref.exists r
	if e
		then inRepo $ Git.Branch.changed b r
		else return False

newer :: Remote.Remote Annex -> Git.Ref -> Annex Bool
newer remote b = do
	let r = remoteBranch remote b
	e <- inRepo $ Git.Ref.exists r
	if e
		then inRepo $ Git.Branch.changed r b
		else return True
