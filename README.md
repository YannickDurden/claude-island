# Claude Island

Suivi des sessions Claude Code dans le notch macOS : sessions et sous-agents en cours, permissions à approuver depuis l'island, questions de Claude, et clic pour revenir dans le terminal (Warp, Terminal, Ghostty) ou la session Claude Desktop.

Tout reste local : l'app reçoit les hooks de Claude Code sur `127.0.0.1:47821`, sans dépendance externe.

## Prérequis

- macOS 15 ou plus
- Xcode installé dans `/Applications` (les macros SwiftUI ne sont pas fournies par les Command Line Tools ; le `Makefile` le sélectionne tout seul)

## Build et installation

```bash
make test      # tests
make run       # lancement en développement
make install   # build release → ~/Applications/ClaudeIsland.app, puis lancement
```

Au premier lancement de l'app installée, elle s'ajoute à l'ouverture de session. Elle reste désactivable dans Réglages Système › Général › Ouverture.

## Hooks Claude Code

Fusionner `hooks.json` dans `~/.claude/settings.json` sans écraser les hooks existants :

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak
jq -s '.[0] as $s | .[1].hooks as $n | $s | .hooks = (reduce ($n | keys[]) as $k (($s.hooks // {}); .[$k] = ((.[$k] // []) + $n[$k])))' \
  ~/.claude/settings.json hooks.json > /tmp/settings.json && mv /tmp/settings.json ~/.claude/settings.json
```

- `SessionStart` passe par une commande `curl` : Claude Code n'accepte pas les hooks `http` pour cet événement.
- Les en-têtes transmettent `WARP_FOCUS_URL`, `TERM_PROGRAM` et `CLAUDE_CODE_HOST_SESSION_ID` pour retrouver le terminal ou la session Desktop.
- App fermée : les hooks échouent sans bloquer, et Claude affiche ses demandes de permission dans le terminal comme d'habitude.

## Points fragiles

Deux mécanismes non documentés par Anthropic, qui peuvent changer avec une mise à jour :

- le registre `~/.claude/sessions/<pid>.json`, lu toutes les 5 s pour afficher les sessions qui n'ont encore envoyé aucun hook ;
- le lien `claude://code/continue?session=local_…`, utilisé pour ouvrir une session Claude Desktop.
