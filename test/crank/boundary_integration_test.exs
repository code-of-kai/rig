defmodule Crank.BoundaryIntegrationTest do
  use ExUnit.Case, async: true

  alias Crank.BoundaryIntegration
  alias Crank.Errors.Violation

  describe "translate_error/2 — invalid_reference (CRANK_DEP_001)" do
    test "produces a CRANK_DEP_001 violation with all required fields populated" do
      error =
        {:invalid_reference,
         %{
           type: :normal,
           from_boundary: BoundaryIntegrationTest.SampleDomain,
           to_boundary: BoundaryIntegrationTest.SampleInfra,
           reference: %{
             from: BoundaryIntegrationTest.SampleDomain,
             to: BoundaryIntegrationTest.SampleInfra.Repo,
             from_function: {:turn, 3},
             type: :alias_reference,
             mode: :runtime,
             file: "lib/sample_domain.ex",
             line: 42
           }
         }}

      assert %Violation{} = violation = BoundaryIntegration.translate_error(error)
      assert violation.code == "CRANK_DEP_001"
      assert violation.severity == :error
      assert violation.rule == :dependency_direction
      assert violation.location.file == "lib/sample_domain.ex"
      assert violation.location.line == 42
      assert violation.location.function == "turn/3"
      assert violation.violating_call.module == BoundaryIntegrationTest.SampleInfra.Repo
      assert violation.context =~ "SampleDomain"
      assert violation.context =~ "SampleInfra"
      assert violation.metadata.from_boundary == BoundaryIntegrationTest.SampleDomain
      assert violation.metadata.to_boundary == BoundaryIntegrationTest.SampleInfra
      assert violation.metadata.boundary_error_type == :normal
    end

    test "produces CRANK_DEP_001 for runtime references too" do
      error =
        {:invalid_reference,
         %{
           type: :runtime,
           from_boundary: SomeDomain,
           to_boundary: SomeInfra,
           reference: %{
             from: SomeDomain,
             to: SomeInfra.Worker,
             from_function: nil,
             file: "lib/some_domain.ex",
             line: 7
           }
         }}

      assert %Violation{} = violation = BoundaryIntegration.translate_error(error)
      assert violation.code == "CRANK_DEP_001"
    end

    test "produces CRANK_DEP_001 for not_exported references" do
      error =
        {:invalid_reference,
         %{
           type: :not_exported,
           from_boundary: SomeDomain,
           to_boundary: OtherBoundary,
           reference: %{
             from: SomeDomain,
             to: OtherBoundary.Internal,
             file: "lib/some_domain.ex",
             line: 12
           }
         }}

      assert %Violation{} = violation = BoundaryIntegration.translate_error(error)
      assert violation.code == "CRANK_DEP_001"
    end
  end

  describe "translate_error/2 — invalid_external_dep_call (CRANK_DEP_001 / CRANK_DEP_003)" do
    test "produces CRANK_DEP_003 when the target app is unclassified" do
      error =
        {:invalid_reference,
         %{
           type: :invalid_external_dep_call,
           from_boundary: MyDomain,
           to_boundary: SomeLib,
           target_app: :unknown_lib,
           reference: %{
             from: MyDomain,
             to: SomeLib.Module,
             from_function: {:turn, 3},
             file: "lib/my_domain.ex",
             line: 100
           }
         }}

      classification = %{pure: [:decimal], impure: [:ecto]}

      violation =
        BoundaryIntegration.translate_error(error,
          third_party_classification: classification,
          main_app: :my_app
        )

      assert %Violation{} = violation
      assert violation.code == "CRANK_DEP_003"
      assert violation.context =~ ":unknown_lib"
    end

    test "produces CRANK_DEP_001 when the target app is in :third_party_impure" do
      error =
        {:invalid_reference,
         %{
           type: :invalid_external_dep_call,
           from_boundary: MyDomain,
           to_boundary: Ecto.Query,
           target_app: :ecto,
           reference: %{
             from: MyDomain,
             to: Ecto.Query,
             from_function: {:turn, 3},
             file: "lib/my_domain.ex",
             line: 50
           }
         }}

      classification = %{pure: [:decimal], impure: [:ecto]}

      violation =
        BoundaryIntegration.translate_error(error,
          third_party_classification: classification,
          main_app: :my_app
        )

      assert %Violation{} = violation
      assert violation.code == "CRANK_DEP_001"
    end
  end

  describe "translate_error/2 — passthrough" do
    test "returns {:passthrough, _} for unclassified_module errors" do
      error = {:unclassified_module, SomeRandom.Module}

      assert {:passthrough, ^error} = BoundaryIntegration.translate_error(error)
    end

    test "returns {:passthrough, _} for cycle errors" do
      error = {:cycle, [A, B, A]}

      assert {:passthrough, ^error} = BoundaryIntegration.translate_error(error)
    end

    test "returns {:passthrough, _} for unknown_dep errors" do
      error = {:unknown_dep, %{name: SomeBoundary, file: "lib/foo.ex", line: 1}}

      assert {:passthrough, ^error} = BoundaryIntegration.translate_error(error)
    end
  end

  describe "translate_diagnostic/2" do
    test "rewrites a Boundary forbidden-reference diagnostic into a Crank-formatted one" do
      diag = %Mix.Task.Compiler.Diagnostic{
        compiler_name: "boundary",
        file: "lib/my_app/domain.ex",
        position: 42,
        message:
          "forbidden reference to MyApp.Repo\n  (references from MyApp.Domain to MyApp.Repo are not allowed)",
        severity: :warning,
        details: nil
      }

      translated = BoundaryIntegration.translate_diagnostic(diag)
      assert translated.compiler_name == "crank"
      assert translated.message =~ "[CRANK_DEP_001]"
      assert translated.message =~ "forbidden reference"
    end

    test "leaves unhandled Boundary diagnostics untouched" do
      diag = %Mix.Task.Compiler.Diagnostic{
        compiler_name: "boundary",
        file: "lib/foo.ex",
        position: 1,
        message: "MyApp.Foo is not included in any boundary",
        severity: :warning,
        details: nil
      }

      translated = BoundaryIntegration.translate_diagnostic(diag)
      assert translated == diag
    end

    test "leaves diagnostics from other compilers untouched" do
      diag = %Mix.Task.Compiler.Diagnostic{
        compiler_name: "elixir",
        file: "lib/foo.ex",
        position: 1,
        message: "unused variable",
        severity: :warning,
        details: nil
      }

      translated = BoundaryIntegration.translate_diagnostic(diag)
      assert translated == diag
    end
  end

  describe "classify_app/3" do
    test "first-party when app matches main_app" do
      classification = %{pure: [:decimal], impure: [:ecto]}
      assert BoundaryIntegration.classify_app(:my_app, :my_app, classification) == :first_party
    end

    test "third_party_pure when in pure list" do
      classification = %{pure: [:decimal], impure: [:ecto]}

      assert BoundaryIntegration.classify_app(:decimal, :my_app, classification) ==
               :third_party_pure
    end

    test "third_party_impure when in impure list" do
      classification = %{pure: [:decimal], impure: [:ecto]}

      assert BoundaryIntegration.classify_app(:ecto, :my_app, classification) ==
               :third_party_impure
    end

    test "third_party_unclassified when in neither list" do
      classification = %{pure: [:decimal], impure: [:ecto]}

      assert BoundaryIntegration.classify_app(:unknown, :my_app, classification) ==
               :third_party_unclassified
    end

    test "handles missing pure/impure keys gracefully" do
      assert BoundaryIntegration.classify_app(:foo, :my_app, %{}) == :third_party_unclassified
    end
  end

  describe "translate_unclassified/2 — CRANK_DEP_002" do
    test "produces a CRANK_DEP_002 violation with all required fields populated" do
      ref = %{
        from: BoundaryIntegrationTest.CallingDomain,
        to: BoundaryIntegrationTest.UnmarkedHelper,
        from_function: {:turn, 3},
        type: :call,
        mode: :runtime,
        file: "lib/calling_domain.ex",
        line: 17
      }

      violation =
        BoundaryIntegration.translate_unclassified(BoundaryIntegrationTest.UnmarkedHelper, ref)

      assert %Violation{} = violation
      assert violation.code == "CRANK_DEP_002"
      assert violation.severity == :error
      assert violation.rule == :unmarked_domain_helper
      assert violation.location.file == "lib/calling_domain.ex"
      assert violation.location.line == 17
      assert violation.location.function == "turn/3"
      assert violation.violating_call.module == BoundaryIntegrationTest.UnmarkedHelper
      assert violation.context =~ "CallingDomain"
      assert violation.context =~ "UnmarkedHelper"
      assert violation.context =~ "use Crank.Domain.Pure"
      assert violation.metadata.helper == BoundaryIntegrationTest.UnmarkedHelper
      assert violation.metadata.from == BoundaryIntegrationTest.CallingDomain
      assert violation.metadata.ref_type == :call
    end

    test "tolerates a reference missing from_function" do
      ref = %{
        from: SomeDomain,
        to: SomeHelper,
        from_function: nil,
        type: :alias_reference,
        mode: :compile,
        file: "lib/some_domain.ex",
        line: 3
      }

      violation = BoundaryIntegration.translate_unclassified(SomeHelper, ref)

      assert violation.code == "CRANK_DEP_002"
      assert violation.location.function == nil
    end
  end
end
