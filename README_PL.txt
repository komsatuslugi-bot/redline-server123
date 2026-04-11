REDLINE - Railway server (minimalny pakiet, tryb 2 graczy)

Co robi ten serwer:
- przyjmuje input klienta (u/d/l/r),
- liczy pozycje po stronie serwera,
- odsyla snapshot pozycji do wszystkich klientow,
- wpuszcza max 2 graczy.

Pliki w tym folderze wrzucasz do osobnego repo na GitHub:
- project.godot
- dedicated_server.gd
- dedicated_server.tscn
- Dockerfile
- .dockerignore

Railway - krok po kroku:
1) New Project -> Deploy from GitHub Repo (repo z tym folderem)
2) Poczekaj az deploy bedzie zielony (Success)
3) Settings -> Networking -> Generate Domain
4) Skopiuj domene, np:
   redline-railway-server-production.up.railway.app

W grze:
1) PLAY -> ONLINE -> JOIN SERVER
2) Wpisz:
   wss://TWOJA-DOMENA.up.railway.app
3) Nie klikaj HOST (HOST jest tylko do lokalnych testow)
4) Drugi gracz robi to samo i wpisuje ten sam adres

Szybki test czy dziala:
- Po wejsciu do ONLINE ma byc widoczna tylko mapa i 2 kolka-postacie.
- Zielone kolko to lokalny gracz, czerwone to drugi gracz.
