"""Printer instructions may change PDF settings, never the selected ICC asset."""
import copy
import unittest

from test_production_assistant import CURRENT, production, proposal


class ProductionPDFSpecTests(unittest.TestCase):
    def result(self, pdf, quotes, current=None, instructions=None):
        current = copy.deepcopy(current or CURRENT)
        raw = proposal({"pdf": pdf}, quotes)
        return production.validate_proposal(raw, current, instructions or "\n".join(dict.fromkeys(quotes.values())))

    def test_explicit_pdfx4_and_printer_condition_become_reviewable_partial_setup(self):
        quotes = {"pdf.target": "Deliver PDF/X-4.",
                  "pdf.output_condition_identifier": "Output condition: Custom Press 7.",
                  "pdf.output_condition": "Description: coated board, Press 7.",
                  "pdf.rendering_intent": "Rendering intent: perceptual.",
                  "pdf.black_point_compensation": "Black point compensation: on."}
        result = self.result({"target": "pdfx4", "output_condition_identifier": "Custom Press 7",
            "output_condition": "coated board, Press 7", "rendering_intent": "perceptual",
            "black_point_compensation": True}, quotes)
        self.assertEqual(result["proposed_job"]["pdf"]["target"], "pdfx4")
        self.assertNotIn("icc_profile", result["proposed_job"]["pdf"])
        self.assertEqual(result["proposed_job"]["pdf"]["text_mode"], "outlines")
        self.assertFalse(result["proposed_job"]["supplier_confirmed"])

    def test_ordinary_cmyk_pdf_can_be_explicitly_requested_without_fabricated_profile(self):
        result = self.result({"target": "cmyk_pdf"}, {"pdf.target": "Supply a CMYK PDF."})
        self.assertEqual(result["proposed_job"]["pdf"]["target"], "cmyk_pdf")
        self.assertEqual(result["proposed_job"]["pdf"]["output_condition_identifier"], "")

    def test_selected_profile_identity_and_current_settings_are_preserved(self):
        current = copy.deepcopy(CURRENT)
        current["pdf"] = dict(production.PDF_DEFAULTS, icc_profile={"name": "Selected printer.icc", "sha256": "a"*64})
        before = copy.deepcopy(current)
        result = self.result({"rendering_intent": "saturation"},
                             {"pdf.rendering_intent": "Use saturation rendering intent."}, current)
        self.assertEqual(result["proposed_job"]["pdf"]["icc_profile"], current["pdf"]["icc_profile"])
        self.assertEqual(current, before)

    def test_profile_selection_hash_rename_or_file_path_cannot_be_proposed(self):
        current = copy.deepcopy(CURRENT)
        current["pdf"] = dict(production.PDF_DEFAULTS, icc_profile={"name": "Printer.icc", "sha256": "a"*64})
        bad = [{"icc_profile": {"name": "Printer.icc", "sha256": "b"*64}},
               {"icc_profile": {"name": "Replacement.icc", "sha256": "a"*64}},
               {"icc_profile": None}, {"icc_path": "/some/local/profile.icc"},
               {"profile_data": "pretend bytes"}]
        for pdf in bad:
            with self.subTest(pdf=pdf), self.assertRaises(production.ProviderError):
                self.result(pdf, {}, current)

    def test_unsupported_targets_and_pdf_controls_are_rejected(self):
        for pdf in [{"target": "pdfx1a"}, {"target": "pdfa"}, {"black_policy": "rich_black"},
                    {"text_mode": "raster"}, {"schema_version": True}, {"trapping": "automatic"}]:
            with self.subTest(pdf=pdf), self.assertRaises(production.ProviderError):
                self.result(pdf, {"pdf.target": "Supply PDF/X-1a."})

    def test_source_must_explicitly_match_pdf_variant_and_rendering_intent(self):
        for pdf, quotes in [({"target": "pdfx4"}, {"pdf.target": "Supply a CMYK PDF."}),
                            ({"target": "cmyk_pdf"}, {"pdf.target": "Supply PDF/X-4."}),
                            ({"target": "pdfx4"}, {}),
                            ({"target": "pdfx4", "rendering_intent": "perceptual"},
                             {"pdf.target": "Supply PDF/X-4.", "pdf.rendering_intent": "Use relative colorimetric."})]:
            with self.subTest(pdf=pdf), self.assertRaises(production.ProviderError):
                self.result(pdf, quotes)

    def test_bpc_boolean_must_match_unambiguous_source(self):
        for value, quote in [(True, "Black point compensation: off."), (False, "BPC enabled."),
                             (True, "BPC on or off, confirm later."), (True, "Turn something on.")]:
            with self.subTest(value=value, quote=quote), self.assertRaises(production.ProviderError):
                self.result({"target": "pdfx4", "black_point_compensation": value},
                    {"pdf.target": "Supply PDF/X-4.", "pdf.black_point_compensation": quote})

    def test_output_condition_text_and_registry_url_are_literal_bounded_metadata(self):
        good = self.result({"target": "pdfx4", "registry_name": "https://www.color.org"},
            {"pdf.target": "Supply PDF/X-4.", "pdf.registry_name": "Registry: https://www.color.org"})
        self.assertEqual(good["proposed_job"]["pdf"]["registry_name"], "https://www.color.org")
        for key, value, quote in [("output_condition_identifier", "Invented Press", "Actual Press"),
                                  ("output_condition", "x"*501, "x"*501),
                                  ("registry_name", "https://user:password@example.com", "https://user:password@example.com"),
                                  ("registry_name", "file:///some/local/profile", "file:///some/local/profile")]:
            with self.subTest(key=key), self.assertRaises(production.ProviderError):
                self.result({"target": "pdfx4", key: value},
                    {"pdf.target": "Supply PDF/X-4.", "pdf."+key: quote})

    def test_negated_or_alternative_targets_are_not_positive_source_evidence(self):
        cases = [("pdfx4", "Do not supply PDF/X-4.", "PDF/X-4"),
                 ("pdfx4", "PDF/X-4 is not accepted.", "PDF/X-4"),
                 ("pdfx4", "Supply PDF/X-4 or a CMYK PDF; confirm which.", "PDF/X-4"),
                 ("pdfx4", "Deliver PDF/X-1a or PDF/X-4.", "PDF/X-4"),
                 ("cmyk_pdf", "Supply PDF/X-1a as a CMYK PDF.", "CMYK PDF")]
        for value, instructions, quote in cases:
            with self.subTest(instructions=instructions), self.assertRaises(production.ProviderError):
                self.result({"target": value}, {"pdf.target": quote}, instructions=instructions)

    def test_new_pdf_setup_cannot_infer_a_target_from_other_metadata(self):
        for pdf, quotes in [({"output_condition_identifier": "Press 7"}, {"pdf.output_condition_identifier": "Output condition: Press 7."}),
                            ({"rendering_intent": "perceptual"}, {"pdf.rendering_intent": "Use perceptual rendering intent."}),
                            ({"black_point_compensation": True}, {"pdf.black_point_compensation": "BPC enabled."})]:
            with self.subTest(pdf=pdf), self.assertRaisesRegex(production.ProviderError, "explicitly requested PDF target"):
                self.result(pdf, quotes)

    def test_negated_and_ambiguous_intent_or_bpc_quotes_require_manual_review(self):
        cases = [("rendering_intent", "perceptual", "Do not use perceptual rendering intent.", "perceptual"),
                 ("rendering_intent", "perceptual", "Use perceptual or relative colorimetric; ask the printer.", "perceptual"),
                 ("black_point_compensation", True, "BPC is not enabled.", "BPC is not enabled."),
                 ("black_point_compensation", True, "BPC is not enabled.", "BPC"),
                 ("black_point_compensation", False, "BPC is not disabled.", "BPC is not disabled.")]
        for field, value, instructions, quote in cases:
            sources = {"pdf.target": "Supply PDF/X-4.", "pdf." + field: quote}
            with self.subTest(field=field, instructions=instructions), self.assertRaises(production.ProviderError):
                self.result({"target": "pdfx4", field: value}, sources, instructions="Supply PDF/X-4.\n" + instructions)

    def test_clearing_existing_conditions_needs_a_matching_explicit_clear_instruction(self):
        current = copy.deepcopy(CURRENT)
        current["pdf"] = dict(production.PDF_DEFAULTS, output_condition_identifier="Press 7", output_condition="Coated board", registry_name="https://www.color.org")
        for field, valid in [("output_condition_identifier", "Clear the output condition identifier."),
                             ("output_condition", "Remove the output condition description."),
                             ("registry_name", "Clear the registry URL.")]:
            result = self.result({field: ""}, {"pdf." + field: valid}, current)
            self.assertEqual(result["proposed_job"]["pdf"][field], "")
            for instructions, quote in [("Bleed stays 3 mm.", "Bleed stays 3 mm."),
                                        ("Do not " + valid.lower(), valid[:-1].lower())]:
                with self.subTest(field=field, instructions=instructions), self.assertRaises(production.ProviderError):
                    self.result({field: ""}, {"pdf." + field: quote}, current, instructions=instructions)
        with self.assertRaises(production.ProviderError):
            self.result({"output_condition": ""}, {"pdf.output_condition": "Clear the output condition identifier."}, current)


if __name__ == "__main__":
    unittest.main()
