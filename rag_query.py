"""
rag_query.py
------------
RAG query pipeline using Amazon Bedrock Knowledge Bases directly via boto3.
Retrieval and generation are handled separately so we have
full visibility into what chunks were retrieved, required for RAGAS evaluation.

Two retrieval modes:
  - semantic:  standard similarity search across all documents
  - filtered:  same search but scoped to a metadata attribute (e.g. year)

This separation is the core technical differentiator from standard KB usage.
"""

import json
import sys
import boto3

# ── Config ───────────────────────────────────────────────────────────────────
AWS_REGION        = sys.argv[1]
KNOWLEDGE_BASE_ID = sys.argv[2]
MODEL_ID        = "amazon.nova-pro-v1:0" # model ID of preference from Bedrock
NUM_RESULTS      = 5 # chunks to retrieve per query
# ─────────────────────────────────────────────────────────────────────────────

bedrock_agent   = boto3.client("bedrock-agent-runtime", region_name=AWS_REGION)
bedrock_runtime = boto3.client("bedrock-runtime", region_name=AWS_REGION)

# ── Retrieval ─────────────────────────────────────────────────────────────────

def retrieve(query: str, metadata_filter: dict = None) -> list[dict]:
    """
    Retrieve relevant chunks from the Knowledge Base.

    Separating retrieval from generation gives us the raw chunks
    to pass to RAGAS as 'contexts' — without this we can't evaluate
    context precision or context recall.

    Args:
        query:           natural language question
        metadata_filter: optional Bedrock metadata filter dict
                         e.g. {"equals": {"key": "year", "value": "2025"}}

    Returns:
        list of chunk dicts with 'text', 'score', and 'metadata'
    """
    params = {
        "knowledgeBaseId": KNOWLEDGE_BASE_ID,
        "retrievalQuery":  {"text": query},
        "retrievalConfiguration": {
            "vectorSearchConfiguration": {
                "numberOfResults": NUM_RESULTS,
            }
        },
    }

    # Attach metadata filter if provided
    if metadata_filter:
        params["retrievalConfiguration"]["vectorSearchConfiguration"][
            "filter"
        ] = metadata_filter

    response = bedrock_agent.retrieve(**params)

    chunks = []
    for result in response["retrievalResults"]:
        chunks.append({
            "text":     result["content"]["text"],
            "score":    result.get("score", 0.0),
            "metadata": result.get("location", {}).get("s3Location", {}),
            "pmid":     result.get("metadata", {}).get("pmid", ""),
            "year":     result.get("metadata", {}).get("year", ""),
            "journal":  result.get("metadata", {}).get("journal", ""),
        })

    return chunks


# ── Generation ────────────────────────────────────────────────────────────────

def generate(query: str, chunks: list[dict]) -> str:
    """
    Generate an answer from retrieved chunks using Nova Pro.

    We build the prompt manually rather than using retrieve_and_generate
    so we control exactly what context is passed and can log it for RAGAS.

    The prompt instructs the model to:
      - answer only from the provided context
      - be concise and clinically accurate
      - not speculate beyond what the sources say
    """
    # Build context block from retrieved chunks
    context_block = "\n\n---\n\n".join([
        f"Source (PMID: {c['pmid']}, {c['year']}):\n{c['text']}"
        for c in chunks
    ])

    prompt = f"""You are a clinical research assistant. Answer the question below using ONLY 
the provided research context. Be concise, accurate, and do not speculate beyond what the 
sources explicitly state. If the context does not contain enough information to answer, 
say so clearly.

CONTEXT:
{context_block}

QUESTION:
{query}

ANSWER:"""
    response = bedrock_runtime.invoke_model(
    modelId=MODEL_ID,
    body=json.dumps({
        "messages": [{"role": "user", "content": [{"text": prompt}]}],
        "inferenceConfig": {
            "maxTokens": 512,
            "temperature": 0.1,
        },
    }),
)

    body = json.loads(response["body"].read())
    return body["output"]["message"]["content"][0]["text"].strip()


# ── Full RAG pipeline ─────────────────────────────────────────────────────────

def rag(query: str, metadata_filter: dict = None) -> dict:
    """
    Run the full RAG pipeline for a single question.

    Returns a dict with everything RAGAS needs:
      - question:  the input query
      - answer:    Nova Pro's generated answer
      - contexts:  list of raw chunk texts (for RAGAS retrieval metrics)
      - chunks:    full chunk objects including metadata (for debugging)
    """
    chunks  = retrieve(query, metadata_filter)
    answer  = generate(query, chunks)

    return {
        "question": query,
        "answer":   answer,
        "contexts": [c["text"] for c in chunks],   # RAGAS expects a list of strings
        "chunks":   chunks,                         # keep full objects for inspection
    }


# ── Batch eval runner ─────────────────────────────────────────────────────────

def run_eval_dataset(eval_dataset: list[dict], metadata_filter: dict = None) -> list[dict]:
    """
    Run the full RAG pipeline over all questions in the eval dataset.
    Attaches ground_truth from the dataset to each result for RAGAS.
    """
    results = []

    for i, item in enumerate(eval_dataset):
        question = item["question"]
        print(f"[{i+1}/{len(eval_dataset)}] {question[:70]}...")

        result = rag(question, metadata_filter)
        result["ground_truth"] = item["ground_truth"]
        results.append(result)

    return results


# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    # Load eval dataset
    with open("eval_dataset.json") as f:
        eval_dataset = json.load(f)

    print("=== RUN 1: Semantic retrieval (no filter) ===\n")
    results_semantic = run_eval_dataset(eval_dataset)

    print("\n=== RUN 2: Filtered retrieval (2025 papers only) ===\n")
    year_filter = {"equals": {"key": "year", "value": "2025"}}
    results_filtered = run_eval_dataset(eval_dataset, metadata_filter=year_filter)

    # Save both runs for RAGAS evaluation
    output = {
        "semantic": results_semantic,
        "filtered": results_filtered,
    }

    with open("rag_results.json", "w") as f:
        json.dump(output, f, indent=2)

    print("\nSaved to rag_results.json")
    print("Next step: run ragas_eval.py")