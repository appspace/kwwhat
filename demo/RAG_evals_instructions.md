# Running RAG evals against the demo

`nao evals` runs LLM-as-judge RAG-triad evals (faithfulness, contextual relevancy, answer relevancy) against the chat agent. The command and its backend route (`POST /api/evals/chat`) live in the nao fork (`nao_chat_fork`), so the demo has to run on an image built from that fork instead of `getnao/nao:latest`.
This isnstructions assume that both kwwhat and nao_chat_fork are cloned in the same folder [GITHUB_FOLDER]

How to run the evals

1. Start Docker Desktop. It isn't running right now.
2. Build the fork image:
cd [GITHUB_FOLDER]/nao_chat_fork && docker build -t nao-fork:evals .
3. Build the demo on top of it and start it. The terminal stays attached to the server, so leave it open:
cd [GITHUB_FOLDER]/kwwhat/demo && docker compose build chat-bi && ./run-demo.sh
4. Open http://localhost:5005 and create an account. Compose shows no volume for the app database, so accounts may not survive --rm runs. Expect to sign up again each time.
5. In a second terminal, run the evals inside the container. nao evals reads ./tests/evals, so it must run from /app/kwwhat:
C=$(docker ps --filter publish=5005 --format '{{.Names}}' | head -1)
docker exec -it $C bash -c 'cd /app/kwwhat && nao evals -s q001 -v'
   - Drop -s q001 to run all three questions.
   - If you didn't do change 3, nao evals prompts for your email and password. Or pass -e NAO_USERNAME=... -e NAO_PASSWORD=... to docker exec.
6. Read the results on the host at chat-bi/tests/outputs/evals_<timestamp>.json. That folder is mounted from the container and gitignored. The command exits with code 1 if any eval fails.
7. When you're done, run docker compose down.