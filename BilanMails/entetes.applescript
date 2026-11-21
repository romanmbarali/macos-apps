-- Liste les mails reçus depuis N heures dans toutes les boîtes de Mail
-- Une ligne par mail : boîte | dossier | date | expéditeur | sujet | lu | répondu
on run argv
	set heures to (item 1 of argv) as integer
	set depuis to (current date) - (heures * hours)
	set ignorer to {"Tous les messages", "Spam", "Corbeille", "Junk", "Deleted Messages", "Drafts", "Brouillons", "Éléments supprimés", "Courrier indésirable", "Boîte d'envoi", "Important", "Suivis", "Archive", "Notes", "Journal", "Historique des conversations", "Tâches"}
	set out to ""
	tell application "Mail"
		repeat with acc in every account
			set nomCompte to name of acc
			repeat with mb in every mailbox of acc
				set nomDossier to name of mb
				if nomDossier is not in ignorer then
					try
						set msgs to (every message of mb whose date received > depuis)
						repeat with m in msgs
							set out to out & nomCompte & " | " & nomDossier & " | " & ((date received of m) as string) & " | " & (sender of m) & " | " & (subject of m) & " | lu=" & (read status of m) & " | répondu=" & (was replied to of m) & linefeed
						end repeat
					on error errMsg
						set out to out & "ERREUR | " & nomCompte & " | " & nomDossier & " | boîte non lue : " & errMsg & linefeed
					end try
				end if
			end repeat
		end repeat
	end tell
	return out
end run
