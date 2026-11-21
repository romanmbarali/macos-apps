-- Affiche le contenu des mails reçus depuis N heures dont le sujet ou l'expéditeur contient un des mots donnés
-- Usage : osascript corps.applescript <heures> "mot 1" "mot 2" ...
on run argv
	set heures to (item 1 of argv) as integer
	set depuis to (current date) - (heures * hours)
	set mots to rest of argv
	set ignorer to {"Tous les messages", "Spam", "Corbeille", "Junk", "Deleted Messages", "Drafts", "Brouillons", "Éléments supprimés", "Courrier indésirable", "Boîte d'envoi", "Important", "Suivis", "Archive"}
	set out to ""
	set vus to {}
	tell application "Mail"
		repeat with acc in every account
			repeat with mb in every mailbox of acc
				if (name of mb) is not in ignorer then
					try
						set msgs to (every message of mb whose date received > depuis)
						repeat with m in msgs
							set s to (subject of m) & " " & (sender of m)
							repeat with k in mots
								if s contains (k as string) then
									set mid to message id of m
									if mid is not in vus then
										set end of vus to mid
										set c to content of m
										if length of c > 2500 then set c to text 1 thru 2500 of c
										set out to out & "===== " & (name of acc) & " | " & ((date received of m) as string) & " | " & (sender of m) & " | " & (subject of m) & linefeed & c & linefeed
									end if
									exit repeat
								end if
							end repeat
						end repeat
					on error errMsg
						set out to out & "ERREUR | " & (name of acc) & " | " & (name of mb) & " | boîte non lue : " & errMsg & linefeed
					end try
				end if
			end repeat
		end repeat
	end tell
	return out
end run
