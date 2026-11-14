=============================================================================
 LagCompensation 1.0.1 - compensacao de lag para SWAT 4 (jogo base, v1.1)
 Roda SOMENTE NO SERVIDOR. Os jogadores nao precisam instalar nada.
=============================================================================

O QUE FAZ
---------
No SWAT 4 original o servidor decide o acerto do tiro com a posicao ATUAL do
alvo. Como o jogador com ping alto ve os outros "no passado", ele mira em
quem esta na tela e o tiro erra. Este mod faz o servidor avaliar cada tiro de
um jogador remoto no instante em que ele viu a cena:

    instante do tiro = agora - (ping + 1 quadro do servidor)

Funciona como o lag compensation do Counter-Strike: se o alvo estava na mira
na tela do atirador, o dano e registrado.


COMO FUNCIONA (resumo tecnico)
------------------------------
1. LagCompensationManager (pacote LagCompensation, so no servidor) grava a
   posicao de cada jogador ~100 vezes por segundo (64 amostras por jogador).
2. As classes base de arma (SwatEquipment.ClipBasedWeapon e RoundBasedWeapon)
   passam o BallisticFire() por um gancho (SwatEquipment.LagCompensationHook).
3. Para cada alvo que se moveu desde o instante do tiro, o raio da bala e
   deslocado pelo mesmo tanto que o alvo andou e testado contra o corpo atual
   dele. Isso equivale a atirar na posicao passada, sem mover ninguem (sem
   efeitos colaterais em fisica, volumes ou triggers).
4. O mundo continua sendo testado com o raio original, entao paredes ainda
   bloqueiam e a penetracao funciona.
5. Os impactos sao ordenados e entregues ao HandleBallisticImpact() original:
   dano, coletes, capacetes, penetracao e efeitos sao os do jogo.


POR QUE OS CLIENTES NAO PRECISAM DO MOD
---------------------------------------
* O pacote LagCompensation.u e marcado como ServerSideOnly e nao esta em
  ServerPackages: nunca e enviado aos clientes.
* O SwatEquipment.u modificado foi "conformado" ao original (pasta
  SystemConform): mantem o MESMO GUID do arquivo original e as mudancas
  ficam numa "geracao 2" que clientes antigos simplesmente ignoram.
  Verificado no cabecalho do pacote:
      original : GUID 0c9771cf-bbfb-4180-b351-c7454103666f, geracao 787/921
      mod      : GUID 0c9771cf-bbfb-4180-b351-c7454103666f, geracoes 787/921 + 807/932
* O Version.ini NAO foi alterado (ModName=SWAT 4), entao o servidor aparece
  normalmente no navegador de servidores do jogo original.
* NENHUM arquivo .ini novo e criado. O anti-cheat do SWAT compara a
  quantidade e o MD5 dos arquivos de configuracao carregados pelo servidor e
  pelo cliente (erro "unexpected number of configuration files"). Por isso a
  configuracao fica dentro do Swat4DedicatedServer.ini / Swat4.ini, que estao
  na lista de excecoes do jogo (o AMMod faz o mesmo).


ESTRUTURA
---------
LagCompensation\
  CompileLagCompensation.bat       compila
  LaunchLagCompensationServer.bat  servidor dedicado com o mod
  LaunchLagCompensation.bat        jogo com o mod (para hospedar sem dedicado)
  System\
    LagCompensation.u              compensador (so servidor)
    SwatEquipment.u                SwatEquipment original + gancho (conformado)
    Swat4DedicatedServer.ini       configuracao do servidor (secao
                                   [LagCompensation.LagCompensationManager])
    Swat4.ini                      idem, para servidor nao dedicado
    Startup.ini, StartupUCC.ini, UCC.ini ...
  SystemConform\                   copias dos .u originais (usadas so na compilacao)
  Source\
    Game\LagCompensation\Classes\  CODIGO DO COMPENSADOR (+ .upkg ServerSideOnly)
    Game\SwatEquipment\Classes\LagCompensation\LagCompensationHook.uc   (novo)
    Game\SwatEquipment\Classes\Bases\ClipBasedWeapon.uc                 (alterado)
    Game\SwatEquipment\Classes\Bases\RoundBasedWeapon.uc                (alterado)
    demais pastas: fonte original do SDK (o UCC exige)


COMPILAR
--------
Execute CompileLagCompensation.bat. Esperado:

    Conforming: SwatEquipment            (so quando o SwatEquipment muda)
    Success - 0 error(s), 0 warning(s)

O aviso "Failed to load '..\SystemConform\LagCompensation.u'" e normal (o
pacote e novo, nao ha original para conformar).

Se alterar algo dentro de Source\Game\SwatEquipment, o UCC recompila e
conforma de novo automaticamente. NUNCA apague a pasta SystemConform nem
troque os arquivos dela: sem ela o SwatEquipment.u ganha um GUID novo e os
clientes originais deixam de conseguir entrar.


USAR NO SERVIDOR
----------------
Rode LaunchLagCompensationServer.bat. As linhas do AMMod que ja existiam no
seu Swat4DedicatedServer.ini foram mantidas. No log do servidor deve aparecer,
a cada mapa carregado:

    Log: Spawning: LagCompensation.LagCompensationManager

As mensagens do proprio mod ("LagCompensation: enabled=True ..." e a saida
do bLogShots) sao logs de script, que o SWAT esconde por padrao. Para ve-las,
comente esta linha na secao [Core.System] do ini do servidor:

    ;Suppress=ScriptLog

Para instalar em outro servidor basta copiar a pasta inteira (Source e
SystemConform so sao necessarios para recompilar).

INSTALAR DIRETO NO Content\System DE UM SERVIDOR (ex.: hospedagem):
  1. Backup do Content\System\SwatEquipment.u (precisa ser o mesmo original:
     361.062 bytes, SHA1 CBA6AC8E063A9EEEDC8C1D1AB90B239712D62EF7)
  2. Copie System\SwatEquipment.u e System\LagCompensation.u para la
  3. No Swat4DedicatedServer.ini de la, em [Engine.GameEngine], adicione
         ServerActors=LagCompensation.LagCompensationManager
     e copie a secao [LagCompensation.LagCompensationManager] do final do
     System\Swat4DedicatedServer.ini deste mod
  4. NAO crie LagCompensation.ini e NAO mexa em ServerPackages


CONFIGURACAO (secao [LagCompensation.LagCompensationManager] no
              Swat4DedicatedServer.ini / Swat4.ini)
-------------------------------------------------------------
  bEnabled=True              liga/desliga
  MaxRewindTime=0.5          rebobinamento maximo (s). Tambem limita abuso de
                             ping falso, ja que parte do ping vem do cliente
  PingScale=1.0              fracao do ping usada
  ExtraRewindTime=0.0        segundos extras
  bAddServerFrameTime=True   soma o tempo medio de um quadro do servidor
  bUseServerMeasuredPing=True  usa a medicao do proprio servidor (GETPING),
                             com fallback para o ping do placar
  SampleInterval=0.01        intervalo entre amostras (historico = 64 x isso)
  TeleportDistance=512       salto maior que isso zera o historico (respawn)
  bCompensateAI=True         compensa tambem a IA (COOP)
  bLogShots=False            True = registra cada acerto compensado no log
                             (exige ;Suppress=ScriptLog comentado)

AJUSTE FINO: ligue bLogShots, teste com um jogador de ping alto contra um
alvo correndo. Se os tiros ainda precisarem ser "puxados para frente" do
alvo, aumente ExtraRewindTime (ex.: 0.03 a 0.05). Se acertos estranhos
acontecerem "atras" do alvo, reduza PingScale.


LIMITACOES CONHECIDAS
---------------------
* Rebobina a POSICAO do alvo, nao a pose (agachar, inclinar) nem a rotacao
  do corpo.
* Taser, spray de pimenta e lancador de pepperball usam logica propria e nao
  sao compensados. Granadas tambem nao.
* Atiradores controlados pela IA e o anfitriao de um servidor nao dedicado
  nao tem latencia, entao nao sao compensados (nao precisam).
* Feito para o jogo base (Content\System). Nao cobre a expansao TSS.
* Testado ate o handshake: o cliente original passa na verificacao de
  conteudo (VERIFIEDCONTENTMD5) com o SwatEquipment.u conformado. A
  verificacao de configuracao foi corrigida na versao 1.0.1 (sem .ini proprio).
  Ainda falta testar a partida em si.
