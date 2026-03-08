"""
ragas_eval.py
-------------
Evaluates RAG pipeline outputs using the RAGAS framework.
Runs evaluation over two result sets (semantic vs filtered retrieval)
and exports a comparison score table to Excel.

Usage:
    pip install ragas boto3 openpyxl pandas
    python ragas_eval.py <region>

Prerequisites:
    - rag_results.json       (output from rag_query.py)
    - eval_dataset.json      (ground truth Q&A pairs)
    - AWS credentials configured with Bedrock access

Evaluator model: Claude Sonnet via Amazon Bedrock
  - Different from ground truth author (Opus)
  - Different from generator (Nova Pro)
  - No circular bias in scoring
"""

import json
import pandas as pd
import sys
import warnings
warnings.filterwarnings("ignore", category=DeprecationWarning)
warnings.filterwarnings("ignore", category=UserWarning)


from ragas import evaluate
from ragas.dataset_schema import SingleTurnSample, EvaluationDataset
from ragas.metrics import (
    Faithfulness,
    AnswerRelevancy,
    ContextPrecision,
    ContextRecall,
    AnswerCorrectness,
)
from ragas.llms import LangchainLLMWrapper
from ragas.embeddings import LangchainEmbeddingsWrapper
from langchain_aws import ChatBedrock, BedrockEmbeddings


# ── Config ───────────────────────────────────────────────────────────────────
AWS_REGION       = sys.argv[1]
EVALUATOR_MODEL  = "eu.anthropic.claude-sonnet-4-6"   # judges the results
EMBEDDING_MODEL  = "amazon.titan-embed-text-v2:0"  # for answer relevancy metric
RAG_RESULTS_FILE = "rag_results.json"
OUTPUT_EXCEL     = "ragas_scores.xlsx"
# ─────────────────────────────────────────────────────────────────────────────


def build_evaluator():
    """
    Set up Claude Sonnet via Bedrock as the RAGAS evaluator LLM.
    Titan Embed v2 is used for the AnswerRelevancy metric which
    requires embeddings to measure semantic similarity.
    """
    llm = LangchainLLMWrapper(
        ChatBedrock(
            model_id=EVALUATOR_MODEL,
            region_name=AWS_REGION,
            model_kwargs={"temperature": 0, "max_tokens": 4096},
        )
    )

    embeddings = LangchainEmbeddingsWrapper(
        BedrockEmbeddings(
            model_id=EMBEDDING_MODEL,
            region_name=AWS_REGION,
        )
    )

    return llm, embeddings


def build_dataset(results: list[dict]) -> EvaluationDataset:
    """
    Convert RAG pipeline outputs into a RAGAS EvaluationDataset.

    RAGAS expects per-sample:
      - user_input:            the question asked
      - response:              the generated answer
      - retrieved_contexts:    list of raw chunk texts used for generation
      - reference:             the ground truth answer
    """
    samples = []
    for r in results:
        samples.append(
            SingleTurnSample(
                user_input=r["question"],
                response=r["answer"],
                retrieved_contexts=r["contexts"],
                reference=r["ground_truth"],
            )
        )
    return EvaluationDataset(samples=samples)


def run_evaluation(dataset: EvaluationDataset, llm, embeddings) -> dict:
    """
    Run RAGAS evaluation across all 5 metrics.

    Metrics explained:
      Faithfulness      - are all claims in the answer supported by the contexts?
                          (answer vs contexts, no ground truth needed)
      AnswerRelevancy   - does the answer address the question asked?
                          (answer + question, uses embeddings)
      ContextPrecision  - are the most relevant chunks ranked highest?
                          (contexts vs ground truth)
      ContextRecall     - do the retrieved chunks cover the ground truth?
                          (contexts vs ground truth)
      AnswerCorrectness - how factually close is the answer to ground truth?
                          (answer vs ground truth, semantic + factual)
    """
    metrics = [
        Faithfulness(llm=llm),
        AnswerRelevancy(llm=llm, embeddings=embeddings),
        ContextPrecision(llm=llm),
        ContextRecall(llm=llm),
        AnswerCorrectness(llm=llm),
    ]

    result = evaluate(dataset=dataset, metrics=metrics)
    return result


def scores_to_dataframe(result, run_label: str) -> pd.DataFrame:
    """Convert RAGAS result to a clean DataFrame with question + scores."""
    df = result.to_pandas()

    # Keep only the columns we care about
    score_cols = [
        "faithfulness",
        "answer_relevancy",
        "context_precision",
        "context_recall",
        "answer_correctness",
    ]

    df = df[["user_input"] + score_cols].copy()
    df.rename(columns={"user_input": "question"}, inplace=True)

    # Add a short question label for readability
    df["question"] = df["question"].str[:60] + "..."
    df["run"] = run_label

    return df


def export_to_excel(df_semantic: pd.DataFrame, df_filtered: pd.DataFrame, path: str):
    """
    Export results to Excel with:
      - Sheet 1: per-question scores for both runs side by side
      - Sheet 2: summary averages comparing semantic vs filtered
    """
    score_cols = [
        "faithfulness",
        "answer_relevancy",
        "context_precision",
        "context_recall",
        "answer_correctness",
    ]

    with pd.ExcelWriter(path, engine="openpyxl") as writer:

        # ── Sheet 1: Full results ─────────────────────────────────────────
        combined = pd.concat([df_semantic, df_filtered], ignore_index=True)
        combined.to_excel(writer, sheet_name="Full Results", index=False)

        # ── Sheet 2: Summary comparison ───────────────────────────────────
        summary = pd.DataFrame({
            "metric":   score_cols,
            "semantic": df_semantic[score_cols].mean().values.round(3),
            "filtered": df_filtered[score_cols].mean().values.round(3),
        })
        summary["delta"] = (summary["filtered"] - summary["semantic"]).round(3)
        summary["winner"] = summary["delta"].apply(
            lambda d: "filtered ↑" if d > 0.01 else ("semantic ↑" if d < -0.01 else "tie")
        )
        summary.to_excel(writer, sheet_name="Summary", index=False)

    print(f"\nExported to {path}")


def main():
    if AWS_REGION is None:
        raise SystemExit("Usage: python ragas_eval.py <region>")

    # Load RAG results
    print(f"Loading {RAG_RESULTS_FILE}...")
    with open(RAG_RESULTS_FILE) as f:
        rag_results = json.load(f)

    semantic_results = rag_results["semantic"]
    filtered_results = rag_results["filtered"]
    print(f"Loaded {len(semantic_results)} semantic results")
    print(f"Loaded {len(filtered_results)} filtered results\n")

    # Set up evaluator
    print("Setting up evaluator (Claude Sonnet via Bedrock)...")
    llm, embeddings = build_evaluator()

    # Build RAGAS datasets
    dataset_semantic = build_dataset(semantic_results)
    dataset_filtered = build_dataset(filtered_results)

    # Run evaluations
    print("\n=== Evaluating Run 1: Semantic retrieval ===")
    result_semantic = run_evaluation(dataset_semantic, llm, embeddings)

    print("\n=== Evaluating Run 2: Filtered retrieval (2025 only) ===")
    result_filtered = run_evaluation(dataset_filtered, llm, embeddings)

    # Convert to DataFrames
    df_semantic = scores_to_dataframe(result_semantic, "semantic")
    df_filtered = scores_to_dataframe(result_filtered, "filtered")

    # Print summary to console
    print("\n=== RESULTS SUMMARY ===\n")
    score_cols = [
        "faithfulness",
        "answer_relevancy",
        "context_precision",
        "context_recall",
        "answer_correctness",
    ]
    print(f"{'Metric':<25} {'Semantic':>10} {'Filtered':>10} {'Delta':>10}")
    print("-" * 60)
    for col in score_cols:
        s = df_semantic[col].mean()
        f = df_filtered[col].mean()
        d = f - s
        arrow = "↑" if d > 0.01 else ("↓" if d < -0.01 else "—")
        print(f"{col:<25} {s:>10.3f} {f:>10.3f} {d:>+9.3f} {arrow}")

    # Export to Excel
    export_to_excel(df_semantic, df_filtered, OUTPUT_EXCEL)
    print(f"\nDone. Open {OUTPUT_EXCEL} to review scores.")


if __name__ == "__main__":
    main()