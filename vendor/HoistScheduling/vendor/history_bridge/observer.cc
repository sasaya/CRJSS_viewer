// OR-Toolsの公開C APIに無い「改善解の通知」だけを補う薄い接続プログラム。
// 数式・検証・描画はJulia側にあります。Pythonは使用しません。
// 別プロセスにすることで、OR-ToolsのスレッドからJuliaを直接呼ばずに済みます。
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <limits>
#include <thread>
#include "ortools/sat/cp_model.pb.h"
#include "ortools/sat/cp_model_solver.h"
#include "ortools/sat/model.h"
#include "ortools/sat/sat_parameters.pb.h"
#include "ortools/sat/util.h"
#include "ortools/util/time_limit.h"

using namespace operations_research;
using namespace operations_research::sat;

// DLL内とこのプログラムでModelの型IDを別々に生成しないよう、公開済み実体を使います。
namespace operations_research::sat {
extern template TimeLimit* Model::GetOrCreate<TimeLimit>();
}

// 書き終わってからrenameするので、Juliaが途中までのデータを読むことはありません。
static void save(const CpSolverResponse& response, const std::string& name) {
  const auto temporary = name + ".tmp";
  std::ofstream output(temporary, std::ios::binary);
  if (!response.SerializeToOstream(&output)) throw std::runtime_error("serialize failed");
  output.close();
  if (!output || std::rename(temporary.c_str(), name.c_str()) != 0)
    throw std::runtime_error("cannot publish response: " + name);
}

int main() {
  try {
    CpModelProto problem;
    SatParameters parameters;
    std::ifstream input("model.bin", std::ios::binary);
    std::ifstream settings("parameters.bin", std::ios::binary);
    if (!problem.ParseFromIstream(&input) || !parameters.ParseFromIstream(&settings))
      throw std::runtime_error("cannot read model/parameters");
    Model model;
    model.Add(NewSatParameters(parameters));
    std::atomic<bool> stop(false), done(false);
    model.GetOrCreate<TimeLimit>()->RegisterExternalBooleanAsLimit(&stop);
    double best = std::numeric_limits<double>::infinity();
    int sequence = 0;
    // Observerは元の変数に復元された解を返します。厳密な改善だけ保存します。
    model.Add(NewFeasibleSolutionObserver([&](const CpSolverResponse& response) {
      if (response.objective_value() >= best) return;
      best = response.objective_value();
      char name[64];
      std::snprintf(name, sizeof(name), "incumbent_%06d.bin", ++sequence);
      save(response, name);
    }));
    // 停止要求はファイルで受け取ります。取得済みの改善解は残ります。
    std::thread monitor([&] {
      while (!done) {
        if (std::ifstream("STOP").good()) stop = true;
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
      }
    });
    CpSolverResponse response;
    try { response = SolveCpModel(problem, &model); }
    catch (...) { done = true; monitor.join(); throw; }
    done = true;
    monitor.join();
    save(response, "final.bin");
    // WindowsのJLLと外部コンパイラー間での終了時デストラクターのABI差を避けます。
    // 全ファイルを閉じ、監視スレッドをjoinした後なので、子プロセスの資源はOSが回収できます。
    std::cout.flush();
    std::cerr.flush();
    std::fflush(nullptr);
    std::_Exit(0);
  } catch (const std::exception& error) {
    std::cerr << error.what() << std::endl;
    return 1;
  }
}
