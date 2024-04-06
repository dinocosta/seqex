export const SetupSequencer = {
  mounted() {
    // Note has been pressed, let's toggle the "bg-orange" class on the note so that,
    // if the note is being added it will show as orange, and if it is being removed we remove the highlight.
    window.addEventListener("phx:sequencer-toggle", ({ detail }) => {
      const selector = `button[phx-value-index='${detail.index}'][phx-value-note='${detail.note}']`;
      document.querySelector(selector).classList.toggle("bg-orange");
    });
  },
};
